package HTTP::LoadGen;

use 5.008008;
use strict;

use HTTP::LoadGen::Run;
use Coro;
use Coro::Semaphore ();
use Coro::Specific ();
use Coro::Timer ();
use Coro::Handle;
use AnyEvent;
no warnings qw/uninitialized/;
use Exporter ();

our $VERSION = '0.06';

BEGIN {
  our %EXPORT_TAGS=
    (
     common=>[qw!loadgen threadnr done userdata options rng rnd delay!],
     const=>\@HTTP::LoadGen::Run::EXPORT,
    );
  my %seen;
  foreach my $v (values %EXPORT_TAGS) {
    undef @seen{@$v} if @$v;
  }
  our @EXPORT_OK=@{$EXPORT_TAGS{all}=[keys %seen]};
}

use constant {
  TD_USER=>0,
  TD_RNG=>1,
  TD_THREADNR=>2,
  TD_DONE=>3,
};

my $td;				# thread specific data
our $o;				# the global config hash

sub rnd;			# predeclaration
sub import {
  my $name=shift;
  local *export=\&Exporter::export;
  Exporter::export_to_level $name, 1, $name, map {
    my $what=$_; local $_;
    if($what eq '-rand') {
      *CORE::GLOBAL::rand=\&rnd;
      ();
    } elsif($what eq ':all') {
      our %EXPORT_TAGS;
      unless( exists $EXPORT_TAGS{sb} ) {
	require HTTP::LoadGen::ScoreBoard;
	require HTTP::LoadGen::Logger;
	HTTP::LoadGen::ScoreBoard->import
	    (@HTTP::LoadGen::ScoreBoard::EXPORT_OK);
	*get_logger=\&HTTP::LoadGen::Logger::get;
	$EXPORT_TAGS{sb}=\@HTTP::LoadGen::ScoreBoard::EXPORT_OK;
	$EXPORT_TAGS{log}=[qw!get_logger!];
	my %seen;
	foreach my $v (values %EXPORT_TAGS) {
	  undef @seen{@$v} if @$v;
	}
	our @EXPORT_OK=@{$EXPORT_TAGS{all}=[keys %seen]};
      }
      $what;
    } else {
      $what;
    }
  } @_;
}

sub create_proc {
  my ($how_many, $init, $handler, $exit)=@_;

  AnyEvent::detect;

  my @watcher;
  my %status;
  my $sem=Coro::Semaphore->new;

  pipe my($r, $w);
  pipe my($r2, $w2);

  for( my $i=0; $i<$how_many; $i++ ) {
    my $pid;
    select undef, undef, undef, 0.1 until defined ($pid=fork);
    unless($pid) {
      close $r;
      close $w2;
      $r2=unblock $r2;
      $init->($i) if $init;
      close $w;			# signal parent
      $r2->readable;		# wait for start signal
      undef $r2;
      my $rc=$handler->($i);

      exit $exit->($i, $rc) if $exit;
      exit $rc;
    }
    push @watcher, AE::child $pid, sub {
      $status{$_[0]}=[($_[1]>>8)&0xff, $_[1]&0x7f, $_[1]&0x80];
      $sem->up;
    };
    $sem->adjust(-1);
  }

  close $w;
  unblock($r)->readable;	# wait for children to finish ChildInit

  return [$w2, $sem, \@watcher, \%status];
}

sub start_proc {
  my ($arr)=@_;
  close $arr->[0];
  $arr->[1]->down;
  return $arr->[3];
}

sub _start_thr {
  my ($threadnr, $sem, $handler)=@_;
  $sem->adjust(-1);
  async {
    $handler->(@_);
    $sem->up;
  } $threadnr;
}

sub ramp_up {
  my ($procnr, $nproc, $start, $max, $duration, $handler)=@_;

  $duration=300 if $duration<=0;

  # begin with $start (system total) threads and start over a period
  # of $duration seconds up to $max threads.

  my $sem=Coro::Semaphore->new(1);
  my $initial_sleep=($nproc + $procnr - $start % $nproc) % $nproc + 1;

  my $i=$procnr;
  for(; $i<$start; $i+=$nproc ) {
    _start_thr $i, $sem, $handler;
  }

  return $sem if $i>=$max;

  my $interval=$duration/($max-$start);
  $initial_sleep*=$interval;
  $interval*=$nproc;

  my $cb=Coro::rouse_cb;

  my $tm;
  $tm=AE::timer $initial_sleep, $interval, sub {
    _start_thr $i, $sem, $handler;
    $i+=$nproc;
    unless ($i<$max) {
      undef $tm;
      $cb->();
    }
  };
  Coro::rouse_wait;

  return $sem;
}

sub threadnr () {$$td->[TD_THREADNR]}
sub done () : lvalue {$$td->[TD_DONE]}
sub userdata () : lvalue {$$td->[TD_USER]}
sub options () {$o}
sub rng () : lvalue {$$td->[TD_RNG]}

sub rnd (;$) {
  my $rng=rng;
  (ref $rng eq 'CODE' ? $rng->($_[0]||1) :
   ref $rng ? $rng->rand($_[0]||1) :
   CORE::rand $_[0]);
}

sub delay {
  my ($prefix, $param)=@_;
  return unless exists $param->{$prefix.'delay'};
  my $sec=$param->{$prefix.'delay'};
  if( exists $param->{$prefix.'jitter'} ) {
    my $jitter=$param->{$prefix.'jitter'};
    $sec+=-$jitter+rnd(2*$jitter);
  }
  Coro::Timer::sleep $sec if $sec>0;
}

my %services=(http=>80, https=>443);

my %known_iterators=
  (
   ''=>sub {
     my $urls=options->{URLList};
     my $nurls=@$urls;
     my $i=0;
     return sub {
       return if $i>=$nurls;
       return $urls->[$i++];
     };
   },
   random_start=>sub {
     my $urls=options->{URLList};
     my $nurls=@$urls;
     my ($i, $off)=(0, int rnd $nurls);
     return sub {
       return if $i>=$nurls;
       return $urls->[($off+$i++) % $nurls];
     };
   },
   follow=>sub {
     my $urls=options->{URLList};
     my $nurls=@$urls;
     my $re=qr!^(https?)://([^:/]+)(:[0-9]+)?(.*)!i;
     my $i=0;
     my @save_delay;
     return sub {
       my ($rc, $el)=@_;

       if( $rc->[RC_STATUS]=~/^3/ and
	   exists $rc->[RC_HEADERS]->{location} and
	   $rc->[RC_HEADERS]->{location}->[0]=~$re ) {
	 # follow location

	 unless( @save_delay ) {
	   @save_delay=@{$el->[RQ_PARAM]}{qw/postdelay postjitter/};
	   @{$el->[RQ_PARAM]}{qw/postdelay postjitter/}=(0,0);
	 }

	 my $scheme=lc($1);
	 return ['GET', $scheme, $2, ($3 ? $3 : $services{$scheme}), $4||'/',
		 {keepalive=>KEEPALIVE}];
       }

       if( @save_delay ) {
	 @{$el->[RQ_PARAM]}{qw/postdelay postjitter/}=@save_delay;
	 @save_delay=();
       }

       return if $i>=$nurls;
       return $urls->[$i++];
     };
   },
   random_start_follow=>sub {
     my $urls=options->{URLList};
     my $nurls=@$urls;
     my $re=qr!^(https?)://([^:/]+)(:[0-9]+)?(.*)!i;
     my ($i, $off)=(0, int rnd $nurls);
     my @save_delay;
     return sub {
       my ($rc, $el)=@_;

       if( $rc->[RC_STATUS]=~/^3/ and
	   exists $rc->[RC_HEADERS]->{location} and
	   $rc->[RC_HEADERS]->{location}->[0]=~$re ) {
	 # follow location

	 unless( @save_delay ) {
	   @save_delay=@{$el->[RQ_PARAM]}{qw/postdelay postjitter/};
	   @{$el->[RQ_PARAM]}{qw/postdelay postjitter/}=(0,0);
	 }

	 my $scheme=lc($1);
	 return ['GET', $scheme, $2, ($3 ? $3 : $services{$scheme}), $4||'/',
		 {keepalive=>KEEPALIVE}];
       }

       if( @save_delay ) {
	 @{$el->[RQ_PARAM]}{qw/postdelay postjitter/}=@save_delay;
	 @save_delay=();
       }

       return if $i>=$nurls;
       return $urls->[($off+$i++) % $nurls];
     };
   },
  );
$known_iterators{default}=$known_iterators{''};

sub loadgen {
  local $o=+{@_==1 ? %{$_[0]} : @_};

  my $nproc=($o->{NWorker}||=1);

  die "'URLList' or 'InitURLs' invalid"
    unless (exists $o->{InitURLs} && ref $o->{InitURLs} eq 'CODE' or
	    exists $o->{URLList} && (!exists $o->{InitURLs} ||
				     exists $known_iterators{$o->{InitURLs}}));

  my $init=sub {
    my ($procnr)=@_;

    $td=Coro::Specific->new();	# thread specific data

    $o->{ProcInit}->($procnr) if exists $o->{ProcInit};

    $o->{before}=sub {
      my ($el)=@_;
      delay 'pre', $el->[5];
      $o->{ReqStart}->($el) if exists $o->{ReqStart};
    };

    $o->{after}=sub {
      my ($rc, $el)=@_;
      $o->{ReqDone}->($rc, $el) if exists $o->{ReqDone};
      return 1 if done;
      delay 'post', $el->[5];
      return;
    };

    if( exists $o->{InitURLs} ) {
      $o->{InitURLs}=$known_iterators{$o->{InitURLs}} unless ref $o->{InitURLs};
    } else {
      $o->{InitURLs}=$known_iterators{''};
    }
  };
  my $exit;
  $exit=$o->{ProcExit} if exists $o->{ProcExit};

  $o->{ParentInit}->() if exists $o->{ParentInit};

  start_proc create_proc $nproc, $init, sub {
    my ($procnr)=@_;

    ramp_up($procnr, $nproc, $o->{RampUpStart}||$nproc,
	    $o->{RampUpMax}||$nproc, $o->{RampUpDuration}||300, sub {
	      my ($threadnr)=@_;

	      my $data=[];
	      $$td=$data;

	      $data->[TD_THREADNR]=$threadnr;
	      $data->[TD_USER]=$o->{ThreadInit}->() if exists $o->{ThreadInit};

	      HTTP::LoadGen::Run::run_urllist $o;

	      $o->{ThreadExit}->() if exists $o->{ThreadExit};
	    })->down;

    return 0;
  }, $exit;

  $o->{ParentExit}->() if exists $o->{ParentExit};
}

1;
