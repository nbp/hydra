package Hydra::Controller::JobsetEval;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub eval : Chained('/') PathPart('eval') CaptureArgs(1) {
    my ($self, $c, $evalId) = @_;
    
    my $eval = $c->model('DB::JobsetEvals')->find($evalId)
	or notFound($c, "Evaluation $evalId doesn't exist.");

    $c->stash->{eval} = $eval;
    $c->stash->{project} = $eval->project;
    $c->stash->{jobset} = $eval->jobset;
}


sub view : Chained('eval') PathPart('') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'jobset-eval.tt';

    my $eval = $c->stash->{eval};

    my $compare = $c->req->params->{compare};
    my $eval2;

    # Allow comparing this evaluation against the previous evaluation
    # (default), an arbitrary evaluation, or the latest completed
    # evaluation of another jobset.
    if (defined $compare && $compare =~ /^\d+$/) {
        $eval2 = $c->model('DB::JobsetEvals')->find($compare)
            or notFound($c, "Evaluation $compare doesn't exist.");
    } elsif (defined $compare && $compare =~ /^($jobNameRE)$/) {
        my $j = $c->stash->{project}->jobsets->find({name => $compare})
            or notFound($c, "Jobset $compare doesn't exist.");
        ($eval2) = $j->jobsetevals->search(
            { hasnewbuilds => 1 },
            { order_by => "id DESC", rows => 1
            , where => \ "not exists (select 1 from JobsetEvalMembers m join Builds b on m.build = b.id where m.eval = me.id and b.finished = 0)"
            });
    } else {
        ($eval2) = $eval->jobset->jobsetevals->search(
            { hasnewbuilds => 1, id => { '<', $eval->id } },
            { order_by => "id DESC", rows => 1 });
    }

    $c->stash->{otherEval} = $eval2 if defined $eval2;
    
    my @builds = $eval->builds->search({}, { order_by => ["job", "system", "id"], columns => [@buildListColumns] });
    my @builds2 = defined $eval2
        ? $eval2->builds->search({}, { order_by => ["job", "system", "id"], columns => [@buildListColumns] })
        : ();

    $c->stash->{stillSucceed} = [];
    $c->stash->{stillFail} = [];
    $c->stash->{nowSucceed} = [];
    $c->stash->{nowFail} = [];
    $c->stash->{new} = [];
    $c->stash->{removed} = [];
    $c->stash->{unfinished} = [];

    my $n = 0;
    foreach my $build (@builds) {
        my $d;
        my $found = 0;
        while ($n < scalar(@builds2)) {
            my $build2 = $builds2[$n];
            my $d = $build->get_column('job') cmp $build2->get_column('job')
                || $build->get_column('system') cmp $build2->get_column('system');
            last if $d == -1;
            if ($d == 0) {
                $n++;
                $found = 1;
                if ($build->finished == 0 || $build2->finished == 0) {
                    push @{$c->stash->{unfinished}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{stillSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{stillFail}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus != 0) {
                    push @{$c->stash->{nowSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus == 0) {
                    push @{$c->stash->{nowFail}}, $build;
                } else { die; }
                last;
            }
            push @{$c->stash->{removed}}, { job => $build2->get_column('job'), system => $build2->get_column('system') };
            $n++;
        }
        push @{$c->stash->{new}}, $build if !$found;
    }
    
    $c->stash->{full} = ($c->req->params->{full} || "0") eq "1";
}


1;
