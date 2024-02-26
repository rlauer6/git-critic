#!/usr/bin/perl

# TODO:
# - usage
# - logging
# - option for output
# - create Docker container

package Git::Critic;

use strict;
use warnings;

use Cwd;
use Data::Dumper;
use English qw(-no_match_vars);
use Git::Raw;
use List::Util qw(none);
use Perl::Critic;

use parent qw(CLI::Simple);

__PACKAGE__->use_log4perl();

########################################################################
sub init {
########################################################################
  my ($self) = @_;

  my $repo = $self->get_repo();

  if ( !$repo ) {
    $repo = getcwd;
    $self->set_repo($repo);
    $self->set_git( Git::Raw::Repository->open($repo) );
  }

  my ($head) = $self->head;

  my $commit_id = $self->get_id || $head;

  if ($commit_id) {
    $self->set_commit( $self->get_git->lookup($commit_id) );
  }

  return $self;
}

########################################################################
sub files_changed {
########################################################################
  my ( $self, @args ) = @_;
  my $options = ref $args[0] ? $args[0] : {@args};

  my ($back) = @{$options}{qw(back)};

  my $prev_commit_id = $self->head($back);
  my $prev_commit    = $self->get_git->lookup($prev_commit_id);

  my $diff   = $self->get_git->diff( { tree => $prev_commit->tree } );
  my @deltas = $diff->deltas();

  return map { $_->old_file()->path } @deltas;
}

########################################################################
sub files_modified {
########################################################################
  my ($self) = @_;

  my $status = $self->get_git->status( {} );

  my @modified;

  foreach ( keys %{$status} ) {
    next if none { $_ eq 'worktree_modified' } @{ $status->{$_}->{flags} };
    push @modified, $_;
  }

  return @modified;
}

########################################################################
sub get_parent {
########################################################################
  my ( $self, @args ) = @_;
  my $options = ref $args[0] ? $args[0] : {@args};

  my ( $commit, $parent ) = @{$options}{qw(commit parent)};

  $commit //= $self->get_commit;
  $parent //= 0;

  my @parents = $commit->parents();

  my $parent_id = $parents[$parent]->id();

  return $self->get_git->lookup($parent_id);
}

########################################################################
sub get_file_list {
########################################################################
  my ( $self, $tree, $path, $file_list ) = @_;

  $path      //= q{};
  $file_list //= [];

  foreach ( $tree->entries ) {

    if ( $_->type == 3 ) {
      push @{$file_list}, $path . $_->name;
      next;
    }

    ($file_list) = $self->get_file_list( $_->object, $path . $_->name . q{/}, $file_list );
  }

  return ( $file_list, $path );
}

########################################################################
sub head {
########################################################################
  my ( $self, $back ) = @_;
  $back //= q{};

  if ($back) {
    $back = q{~} . $back;
  }

  my ($id) = $self->get_git->revparse( 'HEAD' . $back );

  return $id;
}

########################################################################
sub get_file {
########################################################################
  my ( $self, $path, $commit ) = @_;

  $commit //= $self->get_commit;

  die "usage: get_file(path, [commit])\n"
    if !$commit || !$path;

  if ( !ref $commit ) {
    $commit = $self->get_git->lookup($commit);
  }

  my $entry = $commit->tree->entry_bypath($path);

  return $entry->object->content;
}

########################################################################
sub compare_violations {
########################################################################
  my ( $self, @args ) = @_;

  my $options = ref $args[0] ? $args[0] : {@args};

  my ( $severity, $verbose, $path ) = @{$options}{qw(severity verbose path)};

  $severity //= $self->get_severity // 1;
  $verbose  //= $self->get_verbose  // 11;

  my $critic = Perl::Critic->new(
    -profile  => "$ENV{HOME}/.perlcriticrc",
    -severity => $severity // 1,
    -verbose  => $verbose  // 11
  );

  my %status;

  foreach my $file ( $self->files_modified ) {
    next
      if $file !~ /[.]pm[.]in$/xsm;

    my $head = $self->get_file($file);

    my $v1 = critique( $critic, $head );

    my $v2 = critique( $critic, slurp("$path/$file") );

    my @new_violations;

    foreach my $v ( keys %{$v2} ) {
      next if exists $v1->{$v} && $v2->{$v}->[0] <= $v1->{$v}->[0];
      push @new_violations, { $v => $v2->{$v}->[1] };
    }

    my @removed_violations;

    foreach my $v ( keys %{$v1} ) {
      next if exists $v2->{$v} && $v1->{$v}->[0] <= $v2->{$v}->[0];
      push @removed_violations, { $v => $v1->{$v}->[1] };
    }

    $status{$file} = [ $v1, $v2, \@removed_violations, \@new_violations ];
  }

  return \%status;
}

########################################################################
sub critique {
########################################################################
  my ( $critic, $source ) = @_;

  my @violations = $critic->critique( \$source );
  my %violations = map { $_->policy => [ 0, [] ] } @violations;

  foreach (@violations) {
    $violations{ $_->policy }->[0]++;
    push @{ $violations{ $_->policy }->[1] }, $_;
  }

  return \%violations;
}

########################################################################
sub slurp {
########################################################################
  my ($file) = @_;

  local $RS = undef;
  open my $fh, '<', $file
    or die "could not open $file\n";

  my $content = <$fh>;
  close $fh;

  return $content;
}

########################################################################
sub line {
########################################################################
  my ( $self, $n ) = @_;

  return q{-} x $n, "\n";
}

########################################################################
sub short_policy {
########################################################################
  my ($policy) = @_;
  ($policy) = reverse split /::/xsm, $policy;

  return $policy;
}

########################################################################
sub show_violations {
########################################################################
  my ( $self, $status, $fh ) = @_;
  $fh //= *STDOUT;

  foreach my $file ( keys %{$status} ) {
    my $stats = $status->{$file};
    my ( $v1, $v2, $removed, $added ) = @{$stats};

    print {$fh} $self->line(80);
    print {$fh} sprintf '%s', $file;
    print {$fh} sprintf " - removed: [%d] added: [%d]\n", scalar( @{$removed} ), scalar @{$added};
    print {$fh} $self->line(80);

    foreach ( keys %{$v2} ) {
      print {$fh} join q{}, map { "\t[*] " . $_->to_string } @{ $v2->{$_}->[1] };
    }

    if ( @{$added} ) {

      print {$fh} $self->line(80);

      foreach my $v ( @{$added} ) {
        my ($violations) = values %{$v};
        print {$fh} join q{}, map { "\t[+] " . $_->to_string } @{$violations};
      }
    }

    if ( @{$removed} ) {

      print {$fh} $self->line(80);

      foreach ( @{$removed} ) {
        my ( $key, $value ) = %{$_};

        my %old = map { $_->to_string => 1 } @{ $v1->{$key}->[1] };
        my %new = map { $_->to_string => 1 } @{ $v2->{$key}->[1] };

        print {$fh} map { !exists $new{$_} ? "\t[-] $_" : () } keys %old;
      }
    }
  }

  return;
}

########################################################################
sub compare {
########################################################################
  my ($self) = @_;

  my ($status) = $self->compare_violations( path => $self->get_repo );

  $self->show_violations($status);

  return 0;
}

########################################################################
sub main {
########################################################################

  my @option_specs = qw(
    help
    repo=s
    id=s
    severity=s
    verbose=s
    profile
  );

  Getopt::Long::Configure('no_ignore_case');

  return __PACKAGE__->new(
    option_specs  => \@option_specs,
    extra_options => [
      qw(
        git
        commit
      )
    ],
    default_options => {
      id      => q{},
      profile => sprintf '%s/.perlcriticrc',
      $ENV{HOME},
    },
    commands => { compare => \&compare, },
  )->run;
}

exit main();

1;

__END__

=pod

=head1 NAME

Git::Critic - Tool for comparing Perl::Critic result

=head1 SYNOPSIS

=head1 USAGE

git-critic options compare

Executes C<perlcritic> against the current working directory and
compares the results to a previous commit.

 Options
 -------
 --help, -h      help
 --id, -i        commit id to compare
 --repo, -r      repository
 --severity, -s  severity level, default: 1
 --profile, -p   profile, default: $HOME/.perlcriticrc
 --verbose, -v   verbosity level, default: 11

Example:

 git-critic

=head1 AUTHOR

=head1 SEE ALSO

=cut
