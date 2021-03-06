package Hydra::Helper::Nix;

use strict;
use Exporter;
use File::Path;
use File::Basename;
use Hydra::Helper::CatalystUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getHydraPath getHydraHome getHydraDBPath openHydraDB getHydraConf txn_do
    registerRoot getGCRootsDir gcRootFor
    getPrimaryBuildsForView
    getPrimaryBuildTotal
    getViewResult getLatestSuccessfulViewResult jobsetOverview removeAsciiEscapes);


sub getHydraPath {
    my $dir = $ENV{"HYDRA_DATA"} || "/var/lib/hydra";
    die "The HYDRA_DATA directory ($dir) does not exist!\n" unless -d $dir;
    return $dir;
}


sub getHydraHome {
    my $dir = $ENV{"HYDRA_HOME"} or die "The HYDRA_HOME directory does not exist!\n";
    return $dir;
}


sub getHydraConf {
    my $conf = $ENV{"HYDRA_CONFIG"} || (getHydraPath . "/hydra.conf");
    die "The HYDRA_CONFIG file ($conf) does not exist!\n" unless -f $conf;
    return $conf;
}


sub getHydraDBPath {
    my $db = $ENV{"HYDRA_DBI"};
    if ( defined $db ) {
      return $db ;
    }
    else {
        my $path = getHydraPath . '/hydra.sqlite';
        die "The Hydra database ($path) not exist!\n" unless -f $path;
        return "dbi:SQLite:$path";
    }
}


sub openHydraDB {
    my $db = Hydra::Schema->connect(getHydraDBPath, "", "", {});
    $db->storage->dbh->do("PRAGMA synchronous = OFF;")
        if defined $ENV{'HYDRA_NO_FSYNC'};
    return $db;
}


# Awful hack to handle timeouts in SQLite: just retry the transaction.
# DBD::SQLite *has* a 30 second retry window, but apparently it
# doesn't work.
sub txn_do {
    my ($db, $coderef) = @_;
    while (1) {
        eval {
            $db->txn_do($coderef);
        };
        last if !$@;
        die $@ unless $@ =~ "database is locked";
    }
}


sub getGCRootsDir {
    die unless defined $ENV{LOGNAME};
    my $dir = ($ENV{NIX_STATE_DIR} || "/nix/var/nix" ) . "/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";
    mkpath $dir if !-e $dir;
    return $dir;
}


sub gcRootFor {
    my ($path) = @_;
    return getGCRootsDir . "/" . basename $path;
}


sub registerRoot {
    my ($path) = @_;

    my $link = gcRootFor $path;

    if (!-l $link) {
        symlink($path, $link)
            or die "cannot create GC root `$link' to `$path'";
    }
}


sub attrsToSQL {
    my ($attrs, $id) = @_;
    my @attrs = split / /, $attrs;

    my $query = "1 = 1";

    foreach my $attr (@attrs) {
        $attr =~ /^([\w-]+)=([\w-]*)$/ or die "invalid attribute in view: $attr";
        my $name = $1;
        my $value = $2;
        # !!! Yes, this is horribly injection-prone... (though
        # name/value are filtered above).  Should use SQL::Abstract,
        # but it can't deal with subqueries.  At least we should use
        # placeholders.
        $query .= " and exists (select 1 from buildinputs where build = $id and name = '$name' and value = '$value')";
    }

    return $query;
}

sub allPrimaryBuilds {
    my ($project, $primaryJob) = @_;
    my $allPrimaryBuilds = $project->builds->search(
        { jobset => $primaryJob->get_column('jobset'), job => $primaryJob->get_column('job'), finished => 1 },
        { join => 'resultInfo', order_by => "timestamp DESC"
        , '+select' => ["resultInfo.releasename", "resultInfo.buildstatus"]
        , '+as' => ["releasename", "buildstatus"]
        , where => \ attrsToSQL($primaryJob->attrs, "me.id")
        });
    return $allPrimaryBuilds;
}


sub getPrimaryBuildTotal {
    my ($project, $primaryJob) = @_;
    return scalar(allPrimaryBuilds($project, $primaryJob));
}


sub getPrimaryBuildsForView {
    my ($project, $primaryJob, $page, $resultsPerPage) = @_;
    $page = (defined $page ? int($page) : 1) || 1;
    $resultsPerPage = (defined $resultsPerPage ? int($resultsPerPage) : 20) || 20;

    my @primaryBuilds = allPrimaryBuilds($project, $primaryJob)->search( {},
        { rows => $resultsPerPage
        , page => $page
        });

    return @primaryBuilds;
}


sub findLastJobForBuilds {
    my ($ev, $depBuilds, $job) = @_;
    my $thisBuild;

    my $project = $job->get_column('project');
    my $jobset = $job->get_column('jobset');

    # If the job is in the same jobset as the primary build, then
    # search for a build of the job among the members of the jobset
    # evaluation ($ev) that produced the primary build.
    if (defined $ev && $project eq $ev->get_column('project')
        && $jobset eq $ev->get_column('jobset'))
    {
        $thisBuild = $ev->builds->find(
            { job => $job->get_column('job'), finished => 1 },
            { join => 'resultInfo', rows => 1
            , order_by => ["build.id"]
            , where => \ attrsToSQL($job->attrs, "build.id")
            , '+select' => ["resultInfo.buildstatus"], '+as' => ["buildstatus"]
            });
    }

    # As backwards compatibility, find a build of this job that had
    # the primary build as input.  If there are multiple, prefer
    # successful ones, and then oldest.  !!! order_by buildstatus is
    # hacky
    $thisBuild = $depBuilds->find(
        { project => $project, jobset => $jobset
        , job => $job->get_column('job'), finished => 1
        },
        { join => 'resultInfo', rows => 1
        , order_by => ["buildstatus", "timestamp"]
        , where => \ attrsToSQL($job->attrs, "build.id")
        , '+select' => ["resultInfo.buildstatus"], '+as' => ["buildstatus"]
        })
        unless defined $thisBuild;

    return $thisBuild;
}

sub jobsetOverview {
    my ($c, $project) = @_;
    return $project->jobsets->search( isProjectOwner($c, $project) ? {} : { hidden => 0 },
        { order_by => "name"
        , "+select" => 
          [ "(SELECT COUNT(*) FROM Builds AS a NATURAL JOIN BuildSchedulingInfo WHERE me.project = a.project AND me.name = a.jobset AND a.isCurrent = 1)"
          , "(SELECT COUNT(*) FROM Builds AS a NATURAL JOIN BuildResultInfo WHERE me.project = a.project AND me.name = a.jobset AND buildstatus <> 0 AND a.isCurrent = 1)"
          , "(SELECT COUNT(*) FROM Builds AS a NATURAL JOIN BuildResultInfo WHERE me.project = a.project AND me.name = a.jobset AND buildstatus = 0 AND a.isCurrent = 1)"
          , "(SELECT COUNT(*) FROM Builds AS a WHERE me.project = a.project AND me.name = a.jobset AND a.isCurrent = 1)"
          ]
       , "+as" => ["nrscheduled", "nrfailed", "nrsucceeded", "nrtotal"]
       });
}

sub getViewResult {
    my ($primaryBuild, $jobs) = @_;

    my @jobs = ();

    my $status = 0; # = okay

    # Get the jobset evaluation of which the primary build is a
    # member.  If there are multiple, pick the oldest one (i.e. the
    # lowest id).  (Note that for old builds in the database there
    # might not be a evaluation record, so $ev may be undefined.)
    my $ev = $primaryBuild->jobsetevalmembers->find({}, { rows => 1, order_by => "eval" });
    $ev = $ev->eval if defined $ev;

    # The timestamp of the view result is the highest timestamp of all
    # constitutent builds.
    my $timestamp = 0;

    foreach my $job (@{$jobs}) {
        my $thisBuild = $job->isprimary
            ? $primaryBuild
            : findLastJobForBuilds($ev, scalar $primaryBuild->dependentBuilds, $job);

        if (!defined $thisBuild) {
            $status = 2 if $status == 0; # = unfinished
        } elsif ($thisBuild->get_column('buildstatus') != 0) {
            $status = 1; # = failed
        }

        $timestamp = $thisBuild->timestamp
            if defined $thisBuild && $thisBuild->timestamp > $timestamp;

        push @jobs, { build => $thisBuild, job => $job };
    }

    return
        { id => $primaryBuild->id
        , releasename => $primaryBuild->get_column('releasename')
        , jobs => [@jobs]
        , status => $status
        , timestamp => $timestamp
        };
}


sub getLatestSuccessfulViewResult {
    my ($project, $primaryJob, $jobs) = @_;
    my $latest;
    foreach my $build (getPrimaryBuildsForView($project, $primaryJob)) {
        return $build if getViewResult($build, $jobs)->{status} == 0;
    }
    return undef;
}

sub removeAsciiEscapes {
    my ($logtext) = @_;
    $logtext =~ s/\e\[[0-9]*[A-Za-z]//g;
    return $logtext;
}

1;
