#! perl -w

use warnings;
use strict;

use LWP::UserAgent;
use LWP::ConnCache;
use HTML::Parser;
use threads;
use threads::shared;
use Thread::Queue;

sub thread_io ();
sub get_htmltext ($);
sub get_package ($);
sub get_filelist ($);
sub version_cmp ($$);

my $verbose = 1;

my $lwp = LWP::UserAgent->new(agent => 'Mozilla/4.0 (compatible; MSIE 6.0; '.
    'Windows NT 5.1; SV1; .NET CLR 2.0.50727; CIBA)');
my $conncache = LWP::ConnCache->new;
$lwp->conn_cache($conncache);

my $MAX_THREADS = 10;
my $data_queue = Thread::Queue->new;
my $processing_count :shared = 0;
my @filelist :shared = ();


# get MSYS packages
my $sf_head = "http://sourceforge.net/downloads/mingw/MSYS";
my $prj_head = "http://voxel.dl.sourceforge.net/project/mingw/MSYS";
my @files = ();
my $msys_head;
our $head;

for $head (("", "/BaseSystem")) {
    $msys_head = $sf_head . $head;
    my $package_list;
    for (;;) {
        eval { $package_list = get_htmltext $msys_head; };
        last if !$@;
    }
    @filelist = ();

    map { threads->create(\&thread_io) } 1..$MAX_THREADS;

    for (get_filelist $package_list) {
        print "\r[ENQU] pc = $processing_count, pending = ", $data_queue->pending;
        if ($data_queue->pending() > $MAX_THREADS * 2) {
            select(undef, undef, undef, 0.02);
            redo;
        }

        $data_queue->enqueue($_);
    }

    while ($processing_count > 0 or $data_queue->pending > 0) {
        print "\r[WAIT] pc = $processing_count, pending = ", $data_queue->pending;
        select(undef, undef, undef, 0.02);
    }

    print "\r";
    map { $_->detach } threads->list(threads::all);

    @files = (@files, @filelist);
    map { print "$_\n" } sort @filelist;

    if ($head !~ /^$/) {
        $head = (substr $head, 1)."/";
        if (!-d $head) {
            mkdir $head
        }
    }
    open my $fh, ">", "$head!output.txt";
    map { print $fh "$_\n" } sort @filelist;
    close $fh;
}


sub thread_io () {
    while (my $data = $data_queue->dequeue()) {
        {
            lock $processing_count;
            ++$processing_count;
        }

        eval {
            my @list = get_package $data;
            lock @filelist;
            @filelist = (@filelist, grep !/^$/, @list);
        };
        $data_queue->enqueue($data) if $@;

        {
            lock $processing_count;
            --$processing_count;
        }
    }
}


sub get_htmltext ($) {
    my $url = shift;

    my $request = HTTP::Request->new(GET => $url);
    $request->header(Accept => 'text/html');
    my $response = $lwp->request($request);

    if ($response->is_success) {
        print "\r[ OK ] $url\n" if $verbose;
        return $response->decoded_content;
    } else {
        print "\r[FAIL] $url\n\t", $response->status_line, "\n" if $verbose;
        die $response->status_line;
    }
}


sub get_package ($) {
    my $name = shift;
    my ($max_verion, $max_subver, $res) = ([0], 0, "");
    my $version_list = get_htmltext $msys_head .'/'. $name;

    for (get_filelist $version_list) {
        if (/^\w+-(\d+(?:[^-0-9]+\d+)*)\D*(?:-(\d+))?$/) {
            my ($cur_version, $cur_subver) = ([map int, split /\D+/, $1], int($2 || 0));

            my $vcmp = version_cmp($cur_version, $max_verion);
            if ($vcmp > 0 || ($vcmp == 0 && $cur_subver > $max_subver)) {
                $max_verion = $cur_version;
                $max_subver = $cur_subver;
                $res = $_;
            }
        }
    }

    unless ($res) {
        print "\r[SKIP] $name\n" if $verbose;
        return;
    }

    $res = $name .'/'. $res;
    my $files_list = get_htmltext $msys_head .'/'. $res;

    my @filelist = ();
    for (get_filelist $files_list) {
        next if !/msys-.*-(bin|dll|dev|ext)/;

        my $url = $prj_head . $head .'/'. $res .'/'. $_;
        print "\r[URL ] $url\n" if $verbose;
        push @filelist, $url;
        #`wget $url` if !-e $_;
    }

    return @filelist;
}


sub get_filelist ($) {
    my $catch_stack = 0;
    my $cur_addr = 0;
    my @filelist;

    my $parser = HTML::Parser->new(api_version => 3,
        start_h => [sub ($) {
            my ($tagname, $attr) = @_;

            ++$catch_stack
                if $tagname eq "table"
                    && ($attr->{id} eq "files_list" || $catch_stack > 0);

            $cur_addr = $attr->{href}
                if $catch_stack > 0 && $tagname eq "a"
                    && $attr->{href} =~ /files_beta|download/;
        }, "tagname, attr"],

        end_h => [sub ($) {
            my $tagname = shift;
            --$catch_stack if $tagname eq "table" && $catch_stack > 0;
            $cur_addr = undef if $tagname eq "a" && $cur_addr;
        }, "tagname"],

        text_h => [sub ($) {
            my $text = shift;
            push @filelist, $text
                if $catch_stack > 0 && $cur_addr && $text !~ /^(\s*|parent folder)$/i;
        }, "dtext"],
    );

    $parser->parse(shift);
    $parser->eof;

    return @filelist;
}


sub version_cmp ($$) {
    my ($a, $b) = @_;
    my ($ia, $ib) = (0, 0);

    while ($a->[$ia]
        && ($a->[$ia++] || 0) == ($b->[$ib++] || 0)){}

    return ($a->[$ia-1] || 0) <=> ($b->[$ib-1] || 0);
}
