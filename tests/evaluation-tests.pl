use strict;
use Hydra::Schema;
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;
use Cwd;

use Setup;

my $db = openHydraDB;

use Test::Simple tests => 28;

hydra_setup($db);

my $res;
my $stdout;
my $stderr;

my $jobsBaseUri = "file://".getcwd;
my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset;

# Most basic test case, no parameters
$jobset = createBaseJobset("basic", "basic.nix");

ok(evalSucceeds($jobset),                  "Evaluating jobs/basic.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 3 , "Evaluating jobs/basic.nix should result in 3 builds");

for my $build (queuedBuildsForJobset($jobset)) {
  ok(runBuild($build), "Build '".$build->job->name."' from jobs/basic.nix should exit with code 0");
  my $newbuild = $db->resultset('Builds')->find($build->id);
  my $expected = $build->job->name eq "fails" ? 1 : 0;
  ok($newbuild->buildresultinfo->buildstatus == $expected, "Build '".$build->job->name."' from jobs/basic.nix should have buildstatus $expected");
}

# Test jobset with 2 jobs, one has parameter of succeeded build of the other
$jobset = createJobsetWithOneInput("build-output-as-input", "build-output-as-input.nix", "build1", "build", "build1");

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for first time should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
  ok(runBuild($build), "Build '".$build->job->name."' from jobs/basic.nix should exit with code 0");
  my $newbuild = $db->resultset('Builds')->find($build->id);
  ok($newbuild->buildresultinfo->buildstatus == 0, "Build '".$build->job->name."' from jobs/basic.nix should have buildstatus 0");
}

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix for second time should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for second time after building build1 should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
  ok(runBuild($build), "Build '".$build->job->name."' from jobs/basic.nix should exit with code 0");
  my $newbuild = $db->resultset('Builds')->find($build->id);
  ok($newbuild->buildresultinfo->buildstatus == 0, "Build '".$build->job->name."' from jobs/basic.nix should have buildstatus 0");
}


# Test scm inputs 
my @scminputs = ("svn", "svn-checkout", "git", "bzr", "bzr-checkout", "hg");
foreach my $scm (@scminputs) {
  $jobset = createJobsetWithOneInput($scm, "$scm-input.nix", "src", $scm, "$jobsBaseUri/$scm-repo");

  ok(evalSucceeds($jobset),                 "Evaluating jobs/$scm-input.nix should exit with return code 0.");
  ok(nrQueuedBuildsForJobset($jobset) == 1, "Evaluating jobs/$scm-input.nix should result in 1 build in queue");
}

