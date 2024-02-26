#!/usr/bin/perl

package Git::Critic::Analyze;

use strict;
use warnings;

use lib "$ENV{HOME}/lib/perl5";

use Carp;
use Cwd;
use Data::Dumper;
use DBI;
use English qw(-no_match_vars);
use Git::Raw;
use JSON;
use List::Util qw(none);
use Log::Log4perl::Level;
use Perl::Critic;
use Term::ProgressBar;
use Text::CSV_XS;
use Getopt::Long;

use Readonly;

Readonly::Scalar our $DATABASE_NAME => 'git-critic.db';
Readonly::Scalar our $DSN           => 'dbi:SQLite:dbname=' . $DATABASE_NAME;
Readonly::Scalar our $TRUE          => 1;
Readonly::Scalar our $FALSE         => 0;
Readonly::Scalar our $SUCCESS       => 0;

use parent qw(CLI::Simple);

__PACKAGE__->use_log4perl();

########################################################################
sub init {
########################################################################
  my ($self) = @_;

  $self->set_dbi( $self->connect_db );

  $self->_check_format;

  croak 'progress bars are only used when saving to database'
    if $self->get_progress && $self->get__command ne 'save';

  if ( !$self->get_repo_path ) {
    $self->set_repo_path(getcwd);
  }

  if ( $self->get_commit ) {
    $self->set_commit_time( $self->_commit_time() );
  }

  return $TRUE;
}

########################################################################
sub _check_format {
########################################################################
  my ($self) = @_;

  my $format = $self->get_format;

  croak '--format only valid for summary & detail commands'
    if $format && $self->get__command !~ /summary|detail/xsm;

  $format ||= 'json';

  if ( none { $format eq $_ } qw(csv json) ) {
    carp 'invalid format ' . $format . ' using "json"';
    $self->set_format('json');
  }

  return $format;
}

########################################################################
sub connect_db {
########################################################################
  my ($self) = @_;

  my $dbi = DBI->connect($DSN);

  $self->set_dbi($dbi);

  return $dbi;
}

########################################################################
sub disconnect_db {
########################################################################
  my ($self) = @_;

  return
    if !$self->get_dbi || !$self->get_dbi->ping;

  $self->get_dbi->disconnect;

  $self->set_dbi(undef);

  return;
}

########################################################################
sub _db_do {
########################################################################
  my ( $self, $sql, $bind_args ) = @_;

  my $sth = $self->get_dbi->prepare($sql);

  my @bind_args = @{ $bind_args || [] };

  $sth->execute(@bind_args);

  return $sth;
}

########################################################################
sub _delete_commit {
########################################################################
  my ( $self, $id ) = @_;

  $self->_db_do( 'delete from tStats where id = ?', [$id] );

  $self->_db_do( 'delete from tCritic where file_id = ?', [$id] );

  return;
}

########################################################################
sub _find_commit {
########################################################################
  my ( $self, $commit, $filename ) = @_;

  my $dbi = $self->get_dbi;

  my $sql = <<'END_OF_SQL';
SELECT *
  FROM tStats 
  WHERE git_commit = ? and filename = ?
END_OF_SQL

  my $sth = $self->_db_do( $sql, [ $commit, $filename ] );

  my $stat_record = $sth->fetchrow_hashref;

  $sth->finish;

  return $stat_record;
}

########################################################################
sub _find_file {
########################################################################
  my ( $self, $file ) = @_;

  my $dbi = $self->get_dbi;

  my $sql = <<'END_OF_SQL';
SELECT * 
  FROM tStats 
  WHERE filename = ?
  ORDER BY date_inserted DESC
END_OF_SQL

  my $sth = $dbi->prepare($sql);

  $sth->execute($file);
  my @records;

  while ( my $stat_record = $sth->fetchrow_hashref ) {
    push @records, $stat_record;
  }

  $sth->finish;

  return \@records;
}

########################################################################
sub get_last_rowid {
########################################################################
  my ($self) = @_;

  my $sth = $self->get_dbi->prepare('select last_insert_rowid()');
  $sth->execute;

  my ($row_id) = $sth->fetchrow_array;

  return $row_id;
}

########################################################################
{
  my $file_list;

########################################################################
  sub _get_next_file {
########################################################################
    my ($self) = @_;

    if ( !$file_list ) {
      if ( $self->get_input ) {
        $file_list = [ $self->get_input ];
      }
      else {
        while ( my $file = <> ) {
          chomp $file;

          die "file $file not found\n"
            if !-e $file;

          push @{$file_list}, $file;
        }
      }

      my $file_count = @{$file_list};
      $self->set_file_count($file_count);

      if ( $self->get_progress ) {
        $self->set_term_progress( Term::ProgressBar->new($file_count) );
      }
    }

    my $file = shift @{$file_list};

    $self->set_last_file( $self->get_input );

    $self->set_input($file);

    return $file;
  }
}
########################################################################

########################################################################
sub _fetch_stats {
########################################################################
  my ($self) = @_;

  my $critic = $self->get_critic // $self->_analyze();

  return
    if !defined $critic;

  my $statistics = $critic->statistics;

  my $commit = $self->get_commit // q{};

  my $severities = $statistics->violations_by_severity();

  my @stat_record = ( $self->get_input, map { $_ // 0 } @{$severities}{ 1 .. 5 } );

  my $mccabe
    = $statistics->average_sub_mccabe
    ? sprintf '%.2f', $statistics->average_sub_mccabe()
    : 0;

  push @stat_record,
    ( $statistics->lines(), $mccabe, $statistics->subs(), $statistics->total_violations(),
    $commit );

  return \@stat_record;
}

########################################################################
sub _get_output_handle {
########################################################################
  my ($self) = @_;

  my $output = $self->get_output;

  my $fh = eval {
    return *STDOUT
      if !$output;

    open my $fh, '>', $output;  ## no critic (RequireBriefOpen)
    return $fh;
  };

  if ( !$fh || $EVAL_ERROR ) {
    $self->get_logger->error( 'could not open output file: ' . $EVAL_ERROR );
    return;
  }

  return $fh;
}

########################################################################
sub _fetch_violations {
########################################################################
  my ( $self, $violations ) = @_;

  $violations //= $self->get_violations();

  my $commit = $self->get_commit;

  my @violations;

  foreach ( @{$violations} ) {
    push @violations,
      [
      $_->filename, $_->line_number, $_->description, $_->explanation,
      $_->severity, $_->policy,      $_->source,      $commit
      ];
  }

  return \@violations;
}

########################################################################
sub _output_violations {
########################################################################
  my ( $self, $violations ) = @_;

  $violations = $self->_fetch_violations($violations);

  my @header = qw(file line_number description explanation severity commit);

  my $fh = $self->_get_output_handle;

  if ( $self->get_format eq 'csv' ) {
    my $csv = Text::CSV_XS->new;

    $csv->combine(@header);

    print {$fh} $csv->string(), "\n";

    foreach ( @{$violations} ) {
      $csv->combine( @{$_} );

      print {$fh} $csv->string, "\n";
    }
  }
  else {
    my @all_violations;

    foreach ( @{$violations} ) {
      my $row = {};
      @{$row}{@header} = $_;
      push @all_violations, $row;
    }

    print {$fh} JSON->new->pretty->encode( \@all_violations );
  }

  return close $fh;
}

########################################################################
sub _output_stats {
########################################################################
  my ( $self, $stat_records ) = @_;

  my @header = qw(filename sev_1 sev_2 sev_3 sev_4 sev_5 lines avg_mccabe subs violations commit);

  my $fh = $self->_get_output_handle;

  if ( $self->get_format eq 'csv' ) {

    my $csv = Text::CSV_XS->new;

    $csv->combine(@header);

    print {$fh} $csv->string, "\n";

    foreach ( @{$stat_records} ) {
      $csv->combine( @{$_} );
      print {$fh} $csv->string, "\n";
    }
  }
  else {
    my @all_records;

    foreach ( @{$stat_records} ) {
      my $stats = {};
      @{$stats}{@header} = @{$_};
      push @all_records, $stats;
    }

    print {$fh} JSON->new->pretty->encode( \@all_records );
  }

  return close $fh;
}

########################################################################
sub _record_violations {
########################################################################
  my ( $self, $row_id ) = @_;

  my $dbi = $self->get_dbi();

  my $violations = $self->_fetch_violations;
  my $sql        = <<'END_OF_SQL';
INSERT INTO tCritic (
                     file_id, 
                     line_number,
                     description, 
                     explanation, 
                     severity, 
                     policy,
                     source,
                     git_commit,
                     git_commit_time
                    )
             VALUES (
                      ?,
                      ?,
                      ?,
                      ?,
                      ?,
                      ?,
                      ?,
                      ?,
                      ?
                    )
END_OF_SQL

  my $sth = $dbi->prepare($sql);

  foreach my $violation ( @{$violations} ) {
    my ( undef, $line_number, $description, $explanation, $severity, $policy, $source, $commit )
      = @{$violation};

    $sth->execute(
      $row_id,      $line_number, $description,
      $explanation, $severity,    $policy,
      $source,      $commit,      $self->get_commit_time
    );
  }

  return;
}

########################################################################
sub _record_summary {
########################################################################
  my ($self) = @_;

  my $dbi = $self->get_dbi();

  my $sql = <<'END_OF_SQL';
 INSERT INTO tStats (
                     filename,
                     sev_1,
                     sev_2,
                     sev_3,
                     sev_4,
                     sev_5,
                     lines,
                     avg_mccabe,
                     sub,
                     violations,
                     git_commit,
                     git_commit_time
                    )
             VALUES (
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?, 
                     ?
                    )
END_OF_SQL
  my $sth = $dbi->prepare($sql);

  my $stat_record = $self->_fetch_stats;

  $sth->execute( @{$stat_record}, $self->get_commit_time );

  my $row_id = $self->get_last_rowid();

  return $row_id;
}

########################################################################
sub _analyze {
########################################################################
  my ($self) = @_;

  $self->set_critic(undef);

  my $file = $self->_get_next_file;

  return
    if !$file;

  croak "file ($file) not found\n"
    if !-e $file;

  my $git_commit = $self->get_commit;

  if ($git_commit) {
    my $commit = $self->_find_commit( $git_commit, $file );

    if ( $commit && !$self->get_force ) {
      my $message
        = sprintf 'Skipping %s stats on commit %s already exists. Use --force to re-analyze', $file,
        ( substr $git_commit, 0, 5 ) . '...';
      if ( $self->get_progress ) {
        $self->get_term_progress->message($message);
      }
      else {
        carp $message;
      }

      return $FALSE;
    }
    elsif ($commit) {
      $self->_delete_commit( $commit->{id} );
    }
  }

  my $critic = Perl::Critic->new( -profile => $self->get_profile, -severity => 1, -verbose => 11 );

  $self->set_critic($critic);

  my @violations = $critic->critique($file);

  $self->set_violations( \@violations );

  if ( $self->get_logger->level eq $DEBUG ) {
    foreach (@violations) {
      $self->get_logger->debug( $_, sprintf '(%d)', $_->severity() );
    }

    $self->get_logger->debug( Dumper( [ stats => $critic->statistics() ] ) );
  }

  return $critic;
}

########################################################################
sub _calc_average_time {
########################################################################
  my ( $self, $start_time, $files_completed ) = @_;

  my $avg_time = ( time - $start_time ) / $files_completed;

  my $time_remaining = $avg_time * ( $self->get_file_count - $files_completed );

  return ( $avg_time, $time_remaining );
}

########################################################################
{
  my $repo;

  sub _commit_time {
    my ($self) = @_;

    if ( !$repo ) {
      my $path = $self->get_repo_path();

      croak 'no or bad --repo-path first'
        if !$path || !-e "$path/.git/config";

      $repo //= Git::Raw::Repository->open($path);
    }

    croak 'set --commit first'
      if !$self->get_commit;

    my $commit = $repo->lookup( $self->get_commit );

    return $commit->time();
  }
}
########################################################################

########################################################################
# COMMANDS
########################################################################

########################################################################
sub perlcritic_save {
########################################################################
  my ($self) = @_;

  croak 'commit is a required option when saving'
    if !$self->get_commit;

  my $count;

  my $start_time = time;
  my $this_time  = time;

  while (1) {
    my $critic = $self->_analyze();

    if ( defined $critic && $self->get_progress ) {
      my $file = $self->get_input;

      $self->get_term_progress->update( ++$count );
      my ( $avg, $remaining ) = $self->_calc_average_time( $start_time, $count );

      $self->get_term_progress->message(
        sprintf '[%3d/%3d] %s - took: %ds, avg time: %5.2f, est time remaining: %ds',
        $count, ( $self->get_file_count - $count ),
        $file, ( time - $this_time ),
        $avg, int $remaining
      );
    }

    last if !defined $critic;

    $this_time = time;

    next if !$critic;

    my $row_id = $self->_record_summary();

    $self->_record_violations($row_id);
  }

  $self->disconnect_db;

  print {*STDERR} sprintf 'completed in %ds', time - $start_time;

  return $SUCCESS;
}

########################################################################
sub perlcritic_detail {
########################################################################
  my ($self) = @_;

  my @violations;

  while ( my $critic = $self->_analyze() ) {
    push @violations, @{ $self->get_violations // [] };
  }

  $self->_output_violations( \@violations );

  return $SUCCESS;
}

########################################################################
sub perlcritic_summary {
########################################################################
  my ($self) = @_;

  my @stats;

  while ( my $stat_record = $self->_fetch_stats() ) {
    push @stats, $stat_record;
    $self->_analyze();
  }

  $self->_output_stats( \@stats );

  return $SUCCESS;
}

########################################################################
sub create_db {
########################################################################
  my ($self) = @_;

  croak 'database ' . $DATABASE_NAME . ' exists. Use --force'
    if -e $DATABASE_NAME && !$self->get_force;

  if ( -e $DATABASE_NAME ) {
    $self->disconnect_db;
    unlink $DATABASE_NAME;
  }

  my $dbi = $self->connect_db;

  my $sqlStats = <<'END_OF_SQL';
create table tStats (
  id              integer primary key autoincrement,
  filename        text,
  sev_1           integer,
  sev_2           integer,
  sev_3           integer,
  sev_4           integer,
  sev_5           integer,
  lines           integer,
  avg_mccabe      numeric,
  sub             integer,
  violations      integer,
  git_commit      text,
  git_commit_time integer,
  date_inserted timestamp default current_timestamp
);
END_OF_SQL

  my $sqlCritic = <<'END_OF_SQL';
create table tCritic (
  file_id         integer,
  line_number     integer,
  description     text,
  explanation     text,
  severity        integer,
  policy          text,
  source          text,
  git_commit      text,
  git_commit_time integer,
  date_inserted  timestamp default current_timestamp
 );
END_OF_SQL

  $dbi->prepare($sqlStats)->execute;

  $dbi->prepare($sqlCritic)->execute;

  $self->disconnect_db;

  return $SUCCESS;
}

########################################################################
sub find_file {
########################################################################
  my ($self) = @_;

  my ($file) = $self->get_args;

  croak 'no file'
    if !$file;

  print {*STDOUT} JSON->new->pretty->encode( $self->_find_file($file) );

  return $SUCCESS;
}

########################################################################
sub main {
########################################################################

  my @option_specs = qw(
    help
    output=s
    format|f=s
    input=s
    manifest=s
    profile=s
    progress|P
    commit=s
    repo-path=s
    force|F
  );

  my $profile = sprintf '%s/.perlcriticrc', $ENV{HOME};
  $profile = -e $profile ? $profile : q{};

  Getopt::Long::Configure('no_ignore_case');

  return __PACKAGE__->new(
    option_specs  => \@option_specs,
    extra_options => [
      qw(
        commit_time
        critic
        dbi
        file_count
        last_file
        logger
        term_progress
        violations
      )
    ],
    default_options => {
      profile => $profile,
      format  => q{},
      commit  => q{},
    },
    commands => {
      detail  => \&perlcritic_detail,
      summary => \&perlcritic_summary,
      save    => \&perlcritic_save,
      init    => \&create_db,
      find    => \&find_file,
    },
  )->run;
}

exit main();

1;

## no critic (RequirePodSections)

__END__

=pod

=head1 NAME

=head SYNOPSIS

=head1 DESCRIPTION

=head1 TODO

=over 5

=item * create a git commit hook for updating analysis of changed
modules and scripts

=item * create a commit report (report on most recent commit)

=back

=head1 USAGE

git-critic-analyze.pl options detail|summary|save|init

 Options
 -------
 --help, -h      help
 --commit, -c    Git commit value
 --format, -f    output format JSON or CSV (for detail or summary)
 --force, -F     force operation
 --manifest, -m  manifest of files to analayze
 --input, -i     name of input file (default: stdin)
 --output, -o    name of output file (default: stdout)
 --progress, -P  show a progress bar when saving to database

Notes:

 1. if --input not provided script will try to get a list of files to
 analyze from stdin

 2. git commit hash is required when saving results

    analyze.pl -c $(git rev-parse --verify HEAD) save foo.pl

 3. You must use the --force option to overwrite a previous analysis
    of the same file on the same commit

 4. Use --progress to show a progress bar when saving results to the
 SQLite database

Recipes:

 * Analyze all Perl modules and scripts in repo

   git ls-files | grep '\.p[ml]\$' |  analyze.pl -o results.csv -f csv summary

=head1 AUTHOR

=head1 SEE ALSO

L<Perl::Critic>

=cut
