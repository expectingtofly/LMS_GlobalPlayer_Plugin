package Plugins::GlobalPlayerUK::ProtocolHandler;


# Copyright (C) 2021 Stuart McLean

#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
#  MA 02110-1301, USA.

use warnings;
use strict;

use base qw(IO::Handle);

use List::Util qw(min max first);
use JSON::XS;
use Data::Dumper;
use Scalar::Util qw(blessed);
use HTTP::Date;

use POSIX qw(strftime);

use Slim::Utils::Log;
use Slim::Utils::Errno;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Prefs;


use Plugins::GlobalPlayerUK::GlobalPlayerFeeder;
use Plugins::GlobalPlayerUK::WebSocketHandler;

use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;
use constant CHUNK_SECONDS => 10;
use constant END_OF_M3U8 => '#EXT-X-ENDLIST';


Slim::Player::ProtocolHandlers->registerHandler('globalplayer', __PACKAGE__);

my $log = logger('plugin.globalplayeruk');
my $prefs = preferences('plugin.globalplayeruk');

sub isAudio { 1 }

sub isRemote { 1 }

sub canDirectStream { 0 }

sub songBytes { }

sub canSeek { 1 }


sub contentType { 'aac' }

sub formatOverride { 'aac' }


sub audioScrobblerSource {

	# R (radio source)
	return 'R';
}

sub isRepeatingStream { 1 }


sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	main::INFOLOG && $log->is_info && $log->info("action=$action url=$url");

	if ($action eq 'stop') { #skip to next track

		my $song = $client->playingSong();
		my $props = $song->pluginData('props');
		$props->{returnToLive} = 1;
		$song->pluginData( props   => $props );
		main::INFOLOG && $log->is_info && $log->info("Returning to live");
		return 1;
	} elsif ($action eq 'rew') { #skip to start of programme

		my $song = $client->playingSong();
		my $props = $song->pluginData('props');
		$props->{restart} = 1;
		$song->pluginData( props   => $props );
		main::INFOLOG && $log->is_info && $log->info("Skipping back to start of programme");
		return 1;
	}

	return 1;
}


sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("getNextTrack++");

	my $masterUrl = $song->track()->url;
	my $isContinue = 0;
	my $oldm3u8 = '';

	main::INFOLOG && $log->is_info && $log->info("Request for next track " . $masterUrl);
	my $props = $song->pluginData('props');
	if ($props && !$props->{returnToLive}) {
		main::INFOLOG && $log->is_info && $log->info("Continue to next programme");
		my $oldm3u8 = $props->{m3u8};
		my $oldFinish = $props->{finish};
		$props = {
			oldm3u8 => $oldm3u8,
			m3u8	=>	'',
			isContinue => 1,
			havem3u8 => 0,
			oldFinishTime => $oldFinish,
			schedule  => '',
			title => '',
			artwork => '',
			reaTitle => '',
		};
		$song->pluginData( props   => $props );
	} else {
		main::INFOLOG && $log->is_info && $log->info("New Live Station");
		my $newprops = {
			oldm3u8 => '',
			m3u8	=>	'',
			isContinue => 0,
			havem3u8 => 0,
			oldFinishTime => 0,
			schedule  => '',
			title => '',
			artwork => '',
			reaTitle => '',
		};
		$song->pluginData( props   => $newprops );
	}
	$successCb->();

	return;
}


sub transitionType {
	my ( $class, $client, $song, $transitionType ) = @_;
	return 0;
}


sub getm3u8Arr {
	my $url = shift;
	my $cbY = shift;
	my $cbN = shift;
	my $heraldid = _getItemId($url);
	my $ws = Plugins::GlobalPlayerUK::WebSocketHandler->new();
	$ws->wsconnect(
		'wss://metadata.musicradio.com/v2/now-playing',
		sub {#success
			main::DEBUGLOG && $log->is_debug && $log->debug("Connected to WS");
			$ws->wssend('{"actions":[{"type":"subscribe","service":"' . $heraldid . '"}]}');
			$ws->wsreceive(
				0.1,
				sub {
					main::DEBUGLOG && $log->is_debug && $log->debug("Read succeeded");
				},
				sub {
					$log->warn("Failed to read WebSocket");
					$cbN->();
				}
			);
		},
		sub {#fail
			my $result = shift;
			$log->warn("Failed to connect to WebSocket : $result");
			$cbN->();
		},
		sub {#Read
			my $readin = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug("read WS : $readin");
			my $json = decode_json($readin);
			$ws->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $heraldid . '"}]}');
			$ws->wsclose();
			readM3u8(
				$json->{current_show}->{live_restart_url},
				sub {
					my $in = shift;
					$cbY->($in,  $json );

				},
				sub {
					$log->warn("Failed to get m3u8");
					$cbN->();
				}
			);

		}
	);

}


sub close {
	my $self = shift;
	my $v =  ${*$self}{'vars'};

	$v->{'session'}->disconnect;

	main::DEBUGLOG && $log->is_debug && $log->debug('close called');
	if ($v->{'trackWS'}) {
		$v->{'trackWS'}->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $v->{'stationId'} . '"}]}');
		$v->{'trackWS'}->wsclose();
	}

	Slim::Utils::Timers::killTimers($self, \&readWS);
	Slim::Utils::Timers::killTimers($self, \&sendHeartBeat);
	Slim::Utils::Timers::killTimers($self, \&readTrackWS);
	Slim::Utils::Timers::killTimers($self, \&trackMetaData);


	$self->SUPER::close(@_);
}


sub vars {
	return ${ *{ $_[0] } }{'vars'};
}


sub setM3U8Array {
	my $self = shift;
	my $intime = shift;
	my $v        = $self->vars;
	my $fulltime = $intime . '.aac';

	main::INFOLOG && $log->is_info && $log->info('finding place in array for ' . $fulltime);
	my @arr = @{$v->{'m3u8Arr'} };

	main::DEBUGLOG && $log->is_debug && $log->debug('starting ' . ((scalar @arr) - 1));
	for ( my $i = ((scalar @arr) - 1) ; $i >= 7 ; $i -= 2 ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('comparing ' . substr($arr[$i],-19) . ' and ' . $fulltime);
		if (substr($arr[$i],-19) lt $fulltime) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Found it ' . $i . ' had ' . $arr[$i] . ' and ' . $fulltime);
			$v->{'arrayPlace'} = $i;
			return;
		}
		main::INFOLOG && $log->is_info && $log->info('Not Found it ' . $i);
	}
	$v->{'arrayPlace'} = 7; #set it to start

	return;
}


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	main::INFOLOG && $log->info( 'Trying to seek ' . $newtime );

	return { timeOffset => $newtime };
}


sub setTimings {
	my $self = shift;
	my $secondsIn = shift;
	my $v        = $self->vars;
	my $client = ${*$self}{'client'};
	my $song     = ${*$self}{'song'};

	main::DEBUGLOG && $log->is_debug && $log->debug("Setting to $secondsIn ");


	#fix progress bar

	$client->playingSong()->can('startOffset')
	  ? $client->playingSong()->startOffset($secondsIn)
	  : ( $client->playingSong()->{startOffset} = $secondsIn );
	$client->master()->remoteStreamStartTime( time() - $secondsIn );
	$client->playingSong()->duration( $v->{'duration'} );
	$song->track->secs( $v->{'duration'});
	Slim::Music::Info::setDelayedCallback( $client, sub { Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] ); }, 'output-only' );

	return;

}


sub new {
	my $class  = shift;
	my $args   = shift;

	my $song  = $args->{'song'};
	my $props = $song->pluginData('props');

	$log->debug("New called ");

	return undef if !defined $props;

	main::INFOLOG && $log->is_info && $log->info('Props  : ' . Dumper($props));


	my $client = $args->{client};
	my $masterUrl = $song->track()->url;
	main::INFOLOG && $log->is_info && $log->info('Remote streaming  : ' . $masterUrl);

	my $self = $class->SUPER::new;

	main::INFOLOG && $log->is_info && $log->info('set up vars ...');

	my $isSeeking = 0;
	my $seekdata =$song->can('seekdata') ? $song->seekdata : $song->{'seekdata'};
	my $startTime = $seekdata->{'timeOffset'};

	if ($props->{restart}) {
		$startTime = 0;
		$isSeeking = 1;
		$props->{restart} = 0;  #Resetting for in case of next seek.
		$song->pluginData( props   => $props );
		main::DEBUGLOG && $log->is_debug && $log->debug("Restarting at beginning of track");
	}

	if ($startTime) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Proposed Seek $startTime  -  offset $seekdata->{'timeOffset'}");
		$isSeeking = 1;
	}


	my $ws = Plugins::GlobalPlayerUK::WebSocketHandler->new();
	my $heraldid = _getItemId($masterUrl);
	my $bufferLength = getBufferLength();

	if ($props->{isContinue} && (str2time($props->{'oldFinishTime'}) > time() ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug("The last track didn't complete properly for some reason");
		$props->{isContinue} = 0;
		$props->{oldFinishTime} = '';
		$song->pluginData( props   => $props );
	}

	${*$self}{contentType} = 'aac';
	${*$self}{'song'}   = $args->{'song'};
	${*$self}{'client'} = $args->{'client'};
	${*$self}{'url'}    = $args->{'url'};
	${*$self}{'vars'} = {    	# variables which hold state for this instance:
		'inBuf'  => '',      	# buffer of received data
		'outBuf' => '',      	# buffer of processed audio
		'streaming' =>1,    	# flag for streaming, changes to 0 when all data received
		'fetching' => 0,        # waiting for HTTP data
		'firstIn' => 1,        	# Indicator to show this is th first audio chunk
		'arrayPlace'   => 0, 	# Current position in the m3u8 array
		'm3u8Arr' => 0, 		# m3u8 array
		'm3u8' => '',			# URL of the m3u8
		'stationId' => $heraldid,	# Station ID
		'duration' => 0,		# Duration of current live programme
		'havem3u8' => 0,		# Indicator to show that we have the M3U8 URL
		'lastm3u8' => 0,		# The time we last retrieved the contents of the M3U8
		'oldFinishTime' => $props->{oldFinishTime},    #The time the last programme finishied
		'lastArr' => 0,			# The position of the last audio chunk in the current M3U8 array
		'session' 	  => Slim::Networking::Async::HTTP->new,
		'isContinue' => $props->{isContinue},   #Indicator that we are continueing to the next live programme (track)
		'setTimings' => 0,		#Indicator that we have set the current programme timings
		'headers'	=> 0,		#M3U8 headers for http checking
		'ws' => $ws,			# The web socket where we get the programme information
		'trackWS' => 0,			# The web socket where we get the track information
		'trackData' => '',		# Where we hold the track data
		'lastTrackData' => time(),	# Time we got the last track
		'isSeeking' => $isSeeking,	# Are we starting as a result of a seek
		'seekOffset'=> $startTime,	# The seek offset
		'bufferLength' => $bufferLength,	# The preferences for how much buffer time from live edge we use
		'm3u8Delay'	=> 8,		# The seconds between checking for new m3u8 content, this reduces if nothing new.
	};

	#Kick off looking for m3u8
	$ws->wsconnect(
		'wss://metadata.musicradio.com/v2/now-playing',
		sub {#success
			main::DEBUGLOG && $log->is_debug && $log->debug("Connected to WS");
			$ws->wssend('{"actions":[{"type":"subscribe","service":"' . $heraldid . '"}]}');
			$ws->wsreceive(
				0.1,
				sub {
					main::DEBUGLOG && $log->is_debug && $log->debug("Read succeeded");
				},
				sub {
					$log->warn("Failed to read WebSocket");
				}
			);
		},
		sub {#fail
			my $result = shift;
			$log->warn("Failed to connect to WebSocket : $result");
		},
		sub {
			my $readin = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug("message arrived");
			$self->inboundMetaData($readin);
		}
	);

	return $self;
}


sub trackMetaData {
	my $self = shift;
	my $v   = $self->vars;

	#Do we have a websocket ?
	if (!$v->{'trackWS'}) {
		$v->{'trackWS'} = Plugins::GlobalPlayerUK::WebSocketHandler->new();

		#Kick off looking for m3u8
		$v->{'trackWS'}->wsconnect(
			'wss://metadata.musicradio.com/v2/now-playing',
			sub {#success
				main::DEBUGLOG && $log->is_debug && $log->debug("Connected to tracj WS");
				$v->{'trackWS'}->wssend('{"actions":[{"type":"subscribe","service":"' . $v->{'stationId'} . '"}]}');
				$self->sendHeartBeat();
				$self->readTrackWS();

			},
			sub {#fail
				my $result = shift;
				$log->warn("Failed to read WebSocket : $result");
			},
			sub {
				my $readin = shift;
				main::DEBUGLOG && $log->is_debug && $log->debug("message arrived");
				$self->inboundTrackMetaData($readin);
			}
		);
	}
	return;
}


sub inboundTrackMetaData {
	my $self = shift;
	my $metaData = shift;
	my $v        = $self->vars;
	my $song  = ${*$self}{'song'};
	my $client = ${*$self}{'client'};

	if (my $json = decode_json($metaData)) {
		if ( $json->{'now_playing'}->{'type'} eq 'track') {

			my $track = $json->{'now_playing'}->{'title'} . ' by ' . $json->{'now_playing'}->{'artist'};


			main::DEBUGLOG && $log->is_debug && $log->debug("NEW TRACK ...  $track");
			$v->{'trackData'} = $track;
			my $props = $song->pluginData('props');

			$props->{title} = $track;
			$props->{artwork} =  $json->{'now_playing'}->{'artwork'};

			if ($track ne $v->{'trackData'}) {

				Slim::Music::Info::setDelayedCallback(
					$client,
					sub {
						$song->pluginData( props   => $props );
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
					},
					'output-only'
				);
			}
			$v->{'lastTrackData'} = time();

		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("Returning to normal");
			$v->{'lastTrackData'} = 0;
		}

	} else {
		$log->warn(" ws failed with no json ");
	}

}


sub sendHeartBeat {
	my $self = shift;
	my $v        = $self->vars;
	main::DEBUGLOG && $log->is_debug && $log->debug("sending ws heartbeat");
	$v->{'trackWS'}->wssend('heartbeat');
	Slim::Utils::Timers::setTimer($self, time() + 30, \&sendHeartBeat);
}


sub inboundMetaData {
	my $self = shift;
	my $metaData = shift;
	my $v        = $self->vars;
	my $song  = ${*$self}{'song'};

	if (my $json = decode_json($metaData)) {


		my $props = generateProps($json);
		main::DEBUGLOG && $log->is_debug && $log->debug("we have m3u8 : ". $props->{m3u8});

		if (   (length $props->{m3u8} && !$v->{'isContinue'})
			|| ($v->{'isContinue'} && length $props->{m3u8} && ( $props->{'finish'} ne $v->{'oldFinishTime'}))) {

			Slim::Utils::Timers::killTimers($self, \&readWS);

			my $seconds = str2time($props->{'finish'}) - str2time($props->{'start'});
			my $lastArray = ((int($seconds/CHUNK_SECONDS) * 2 ) ) + 7; #Probably 2 too many, but we want overhang.

			$v->{'lastArr'} = $lastArray;
			$v->{'duration'} = $seconds;
			main::DEBUGLOG && $log->is_debug && $log->debug("Last array : $lastArray duration $seconds");

			$v->{'ws'}->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $v->{'stationId'} . '"}]}');
			$v->{'ws'}->wsclose();
			$v->{'m3u8'} = $props->{m3u8};
			$v->{'havem3u8'} = 1;
			$song->pluginData( props   => $props );
			main::DEBUGLOG && $log->is_debug && $log->debug("Closed Initial Web Socket");
			return;
		}


	} else {
		$log->warn("Could not decode JSON");
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("Initiate original meta timer");
	Slim::Utils::Timers::setTimer($self, time() + 1, \&readWS);


	return;
}


sub readWS {
	my $self = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("Attempting read on WS");

	my $v = $self->vars;
	$v->{'ws'}->wsreceive(
		0.1,
		sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("Read succeeded on initial WS");
		},
		sub {
			$log->warn("Failed to read recursive WebSocket");
		},
		sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("Nothing there kick off timer again");
			Slim::Utils::Timers::setTimer($self, time() + 1, \&readWS);
		}
	);

	return;
}


sub readTrackWS {
	my $self = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("Attempting read on track WS");

	my $v = $self->vars;
	$v->{'trackWS'}->wsreceive(
		0.1,
		sub {
			Slim::Utils::Timers::setTimer($self, time() + 5, \&readTrackWS);
		},
		sub {
			$log->warn("Failed to read track WebSocket");
		},
		sub {
			Slim::Utils::Timers::setTimer($self, time() + 5, \&readTrackWS);
		}
	);

	if ( ($v->{'lastTrackData'} + 120) < time() ) {
		my $song  = ${*$self}{'song'};
		my $props = $song->pluginData('props');
		my $client = ${*$self}{'client'};

		$props->{title} = $props->{realTitle};
		$props->{artwork} =  $props->{realArtwork};

		Slim::Music::Info::setDelayedCallback(
			$client,
			sub {
				$song->pluginData( props   => $props );
				Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
			},
			'output-only'
		);
		$v->{'lastTrackData'} = time();
	}

	return;
}


sub sysread {
	use bytes;

	my $self = $_[0];

	# return in $_[1]
	my $maxBytes = $_[2];
	my $v        = $self->vars;
	my $song      = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;

	my @m3u8arr = ();


	if ( !$v->{'fetching'} ) {
		if ($v->{'havem3u8'} && $v->{'m3u8Arr'}) {
			@m3u8arr = @{$v->{'m3u8Arr'}};

			# need more data
			if (   length $v->{'outBuf'} < MIN_OUT
				&& !$v->{'fetching'}
				&& $v->{'streaming'}
				&& ($v->{'arrayPlace'} < scalar @m3u8arr ) ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Getting more data");
				$v->{'fetching'} = 1;

				if ( $v->{'firstIn'} ) {

					#Find starting point, always start from live, as we can't continue even if we have paused/rewound
					my $epoch = time() - $v->{'bufferLength'};
					main::DEBUGLOG && $log->is_debug && $log->debug("Initial live time : $epoch ");

					if ($v->{'isSeeking'}) {
						my $props = $song->pluginData('props');
						my $seekepoch = str2time($props->{'start'}) + $v->{'seekOffset'};

						if ($seekepoch < $epoch) {
							$epoch = $seekepoch;
						} else {
							$v->{'isSeeking'} = 0;
						}

						main::DEBUGLOG && $log->is_debug && $log->debug("Seeking and using the time : $epoch ");
					}
					my $liveTime = strftime( '%Y%m%d_%H%M%S', localtime($epoch) );

					$self->setM3U8Array($liveTime);

					#if its the last one in the m3u8 it doesn't give enough time and you get a pause, so adjusting
					if (!$v->{'isSeeking'} && ( $v->{'arrayPlace'} != 7) && (scalar @m3u8arr == ($v->{'arrayPlace'} + 1))) {
						$v->{'arrayPlace'} -= 2;
						main::DEBUGLOG && $log->is_debug && $log->debug("Reducing start point to allow startup");
					}

					$self->setTimings((($v->{'arrayPlace'} - 7) / 2) * 10 );
					$v->{'setTimings'} = 1;
					if (!$v->{'isSeeking'} ) {

						# start listening to track meta data in 15 seconds to give time to see programme
						Slim::Utils::Timers::setTimer($self, time() + 15, \&trackMetaData);
					}
					$v->{'firstIn'} = 0;
				}

				if ((!$v->{'setTimings'}) && $v->{'duration'} ) {
					$self->setTimings((($v->{'arrayPlace'} - 7) / 2) * 10 );
					$v->{'setTimings'} = 1;
				}

				my $url = $m3u8arr[$v->{'arrayPlace'}];
				main::DEBUGLOG && $log->is_debug && $log->debug("Now at  $v->{'arrayPlace'} ending at $v->{'lastArr'} ");

				$v->{'arrayPlace'} += 2;

				my $headers = [ 'Connection', 'keep-alive' ];
				my $request = HTTP::Request->new( GET => $url, $headers);
				$request->protocol('HTTP/1.1');


				$v->{'session'}->send_request(
					{
						request => $request,
						onBody => sub {
							my $response = shift->response;
							main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: " . length $response->content . " for $url");
							$v->{'inBuf'} .= $response->content;
							if ($v->{'arrayPlace'} > $v->{'lastArr'}) {
								main::DEBUGLOG && $log->is_debug && $log->debug("Last item end streaming $v->{'lastArr'} ");
								$v->{'streaming'} = 0;
							}
							$v->{'fetching'} = 0;
						},
						onError => sub {

							$v->{'fetching'} = 0;
							$v->{'streaming'} = 0;
							$log->error("Failed to stream");
						}
					}
				);
			}
		}
	}


	# process all available data
	if ( length $v->{'inBuf'} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Procesing In Buffer');
		$v->{'outBuf'} .=   $v->{'inBuf'};
		$v->{'inBuf'} = '';
	}
	if (my $bytes = min( length $v->{'outBuf'}, $maxBytes ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Bytes . ' . $maxBytes . ' . ' . length $v->{'outBuf'});
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes, '' );

		return $bytes;
	} elsif ( $v->{'streaming'} ) {
		if ($v->{'havem3u8'}) {
			if ( !$v->{'m3u8Arr'} || (($v->{'arrayPlace'} > scalar @m3u8arr) && (!$v->{'fetching'}) && ( ($v->{'lastm3u8'} + $v->{'m3u8Delay'}) < time() ) ))  {
				main::DEBUGLOG && $log->is_debug && $log->debug('Getting Fresh M3u8 ' . Time::HiRes::time());
				$v->{'fetching'} = 1;
				readM3u8(
					$v->{'m3u8'},
					sub {
						my $in=shift;
						my $headers = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug('Have Array #' . scalar @{$in});
						$v->{'m3u8Arr'} =$in;
						$v->{'lastm3u8'} = time();
						$v->{'headers'} = $headers;

						my @lastCheckArr = @{$v->{'m3u8Arr'}};
						main::DEBUGLOG && $log->is_debug && $log->debug('last item  ' . $lastCheckArr[-1]);

						if ($lastCheckArr[-1] eq END_OF_M3U8) {
							main::DEBUGLOG && $log->is_debug && $log->debug('New last array from ' . $v->{'lastArr'});
							$v->{'lastArr'} = (scalar @lastCheckArr) - 2;
							main::DEBUGLOG && $log->is_debug && $log->debug('setting last array to ' . $v->{'lastArr'});

						}
						$v->{'m3u8Delay'} = 8;
						$v->{'fetching'} = 0;

					},
					sub {
						my $connected = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug('No new M3u8 available');
						$v->{'lastm3u8'} = time();
						if ($connected) {
							$v->{'m3u8Delay'} = 1;
						} else {
							$v->{'m3u8Delay'} = 8;
						}
						$v->{'fetching'} = 0;
					},
					$v->{'headers'},
				);

			}
		}
		$! = EINTR;
		return undef;
	}

	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info("end streaming");


	return 0;
}


sub getBufferLength {
	my $bufferPrefs = $prefs->get('buffer');

	my $buffer = 50;

	if ( $bufferPrefs == 0 ) { #short
		$buffer = 40;
	} elsif ( $bufferPrefs == 2 ) {#long
		$buffer = 60;
	}
	main::INFOLOG && $log->is_info && $log->info("Buffer set to $buffer");
	return $buffer;
}


sub generateProps {
	my $json = shift;

	my $props = {
		m3u8 => $json->{current_show}->{live_restart_url},
		start => $json->{current_show}->{start},
		finish => $json->{current_show}->{finish},
		title =>  $json->{current_show}->{name},
		realTitle =>  $json->{current_show}->{name},
		schedule =>  $json->{current_show}->{schedule},
		programmeId =>  $json->{current_show}->{programme_id},
		artwork =>  $json->{current_show}->{artwork},
		realArtwork => $json->{current_show}->{artwork},

	};
	main::DEBUGLOG && $log->is_debug && $log->debug('Props : ' . Dumper($props));
	return $props;

}


sub readM3u8 {
	my ( $m3u8, $cbY, $cbN, $headers ) = @_;


	my $session = Slim::Networking::Async::HTTP->new;

	my $request = HTTP::Request->new( GET => $m3u8 );
	if ($headers) {
		$request->header( 'If-Modified-Since' => $headers->header('Last-Modified') );
		$request->header( 'If-None-Match' => $headers->header('ETag') );
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('dump headers : ' . Dumper($request->headers));

	$session->send_request(
		{
			request => $request,
			onBody => sub {
				my ( $http, $self ) = @_;
				my $response = $http->response;

				main::DEBUGLOG && $log->is_debug && $log->debug('Body code : ' . $response->code);

				if ($response->code == 304) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Nothing New ');
					$cbN->(1);
				} else {

					my $res = $response->content;
					my @m3u8arr = split /\n/, $res;
					main::DEBUGLOG && $log->is_debug && $log->debug('m3u8 array size : ' . scalar @m3u8arr);

					$cbY->(\@m3u8arr, $response->headers);
				}

			},
			onError => sub {
				my ( $http, $error ) = @_;

				$log->warn('Failed to get M3u8 with error : ' . $error);
				$cbN->(0);

			}
		}
	);

	return;
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;

	my ($url) = $full_url =~ /([^&]*)/;
	my $song = $client->playingSong();

	my $meta = {title => $url};
	if ( $song && $song->currentTrack()->url eq $full_url ) {
		if (my $props = $song->pluginData('props') ) {
			$meta = {
				title => $props->{'title'},
				cover => $props->{'artwork'},
				artist => $props->{'realTitle'} . ' ' . $props->{'schedule'},
				type => 'AAC',
				bitrate => 'VBR',
			};

		}
	}
	return $meta;
}


sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	$log->debug("Entering with $uri");

	if ( $uri =~ /^globalplayer:/) {
		if ( $uri =~ /_playlist_/gm){
			my $id = _getItemId($uri);
			Plugins::GlobalPlayerUK::GlobalPlayerFeeder::getPlaylistStreamUrl(
				$id,
				sub {
					my $stream = shift;

					$cb->([$stream]);
				},
				sub {
					$log->error("Failed to get playlist stream URL");
					$cb->([$uri]);
				}
			);
		} elsif ( $uri =~ /_catchup_|_podcast_/) {
			if ($main::VERSION lt '8.2.0') {
				$log->warn("Global Player Favourites only supported in LMS 8.2.0 and greater");
				$cb->(['Global Player Favourites require LMS 8.2.0 or greater']);
				return;
			}

			my $id = _getItemId($uri);

			if ( $uri =~ /_catchup_/ ) {
				Plugins::GlobalPlayerUK::GlobalPlayerFeeder::callAPI(undef, $cb, undef, { call => 'StationCatchupItems', id => $id } );
			} else { #podcast
				Plugins::GlobalPlayerUK::GlobalPlayerFeeder::callAPI(undef, $cb, undef, { call => 'PodcastEpisodes', id => $id } );
			}


		}else {
			$cb->([$uri]);
		}

	} else {
		$cb->([$uri]);
	}

	return;
}


sub _getItemId {
	my $url  = shift;

	my @id  = split /_/x, $url;
	return $id[2];
}

1;