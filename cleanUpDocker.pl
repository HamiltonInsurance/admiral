#!/usr/bin/env perl

use strict;
use Getopt::Long;


my $force;
my $verbose;
GetOptions(
    "force" => \$force,
    "verbose" => \$verbose
);

my $runningImages = `docker ps --format '{{ json .Image}}' | jq --slurp '.'`;
my $storedImages = `docker image ls --format '{{ json . }}' | jq -c --slurp '. | group_by(.ID) | .[] | {id: .[0].ID, size: .[0].Size, images: [.[] | (.Repository + ":" + .Tag)]}'`;
my @runningImages = split(" ", $runningImages);
my @storedImages = split(" ", $storedImages);

my $deletedImages = 0;
my $simulatedDeletedImages = 0;
my $undeletableImages = 0;

foreach my $imageList (@storedImages) {
    #print $imageList;
    my $imageId = `echo '$imageList' | jq -r ".id"`;
    chomp $imageId;
    my $imageTags = `echo '$imageList' | jq -r ".images[]"`;

    #push (@imageTags, $imageId);
    my @imageTags = split(/\n/, $imageTags);

    my $found=0; 

    foreach my $tag (@imageTags) { 
        if(grep(/$tag/, @runningImages)) { 
            $found++;
        }
        if(grep(/$imageId/, @runningImages)) {
            $found++;
        }
    }
    if($found < 1) {
        if($verbose && $force) {
            print "Deleting $imageId\n";
        } elsif ($verbose) {
            print "Would have deleted $imageId\n";
        }
        
        if($force) {
            my $__ = `docker rmi --force $imageId`;
            if($? == 0) {
                $deletedImages++;
            } else {
                $undeletableImages++;
            }
        } else {
            $simulatedDeletedImages++;
        }
    }
}   

    print " Deleted $deletedImages images.\n Would have deleted $simulatedDeletedImages \n Failed to delete $undeletableImages\n"
