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
use Plugins::GlobalPlayerUK::simpleAsyncWS;
use Plugins::GlobalPlayerUK::SegmentUtils;

use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;
use constant CHUNK_SECONDS => 9.98;
use constant END_OF_M3U8 => '#EXT-X-ENDLIST';
use constant RETRY_LIMIT => 3;


Slim::Player::ProtocolHandlers->registerHandler('globalplayer', __PACKAGE__);

my $log = logger('plugin.globalplayeruk');
my $prefs = preferences('plugin.globalplayeruk');
my $uaString = Slim::Utils::Misc::userAgentString();
$uaString =~ s/iTunes\/4.7.1/Mozilla\/5.0/;

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

	my $track = $song->track;
	$track->content_type( 'aac' );
	$track->update;
	$successCb->();

	return;
}


sub transitionType {
	my ( $class, $client, $song, $transitionType ) = @_;
	return 0;
}


sub close {
	my $self = shift;
	my $v =  ${*$self}{'vars'};


	main::DEBUGLOG && $log->is_debug && $log->debug('close called');
	if ($v->{'trackWS'}) {
		$v->{'trackWS'}->send('{"actions":[{"type":"unsubscribe","stream_id":"' . $v->{'stationId'} . '"}]}');
		$v->{'trackWS'}->close();	}

	
	Slim::Utils::Timers::killTimers($self, \&sendHeartBeat);
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
	my $fulltime = $intime * 1000;

	main::INFOLOG && $log->is_info && $log->info('finding place in array for ' . $fulltime);
	my @arr = @{$v->{'m3u8Arr'} };

	main::DEBUGLOG && $log->is_debug && $log->debug('starting ' . ((scalar @arr) - 1));
	for ( my $i = ((scalar @arr) - 1) ; $i >= 6 ; $i -= 2 ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('comparing ' . substr($arr[$i],0,13) . ' and ' . $fulltime);
		if (int(substr($arr[$i],0,13)) < $fulltime) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Found it ' . $i . ' had ' . $arr[$i] . ' and ' . $fulltime);
			$v->{'arrayPlace'} = $i;
			return;
		}
		main::INFOLOG && $log->is_info && $log->info('Not Found it ' . $i);
	}
	$v->{'arrayPlace'} = 6; #set it to start

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
		main::DEBUGLOG && $log->is_debug && $log->debug("Proposed Seek $startTime  -  offset $seekdata->{'timeOffset'}   ");

		#We can only recover from a pause if we are within the current programme
		if ( (!$props->{'finish'}) || str2time($props->{'finish'}) < time() ) {
			$log->warn('Not seeking and returning to live as paused too long');
			$isSeeking = 0;
		} else {
			$isSeeking = 1;
		}
	}

	my $connected = 0;
	my $ws = Plugins::GlobalPlayerUK::simpleAsyncWS->new( 'wss://metadata.musicradio.com/v2/now-playing',
		sub {
			main::DEBUGLOG && $log->is_debug && $log->debug("Connect Succeeeded");	
			$connected = 1;		
		},
		sub {
			$log->error("Failed to Connect to web socket");
			return;
		},

	);

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
		'onlyMaster' => 0,		# Indicator to show that we have the M3U8 URL
		'lastm3u8' => 0,		# The time we last retrieved the contents of the M3U8
		'lastArraySize' => 0,
		'oldFinishTime' => $props->{oldFinishTime},    #The time the last programme finishied
		'lastArr' => 0,			# The position of the last audio chunk in the current M3U8 array
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
		'retryCount' => 0,      # Streaming retries
	};

	#Kick off looking for m3u8

	if ($connected) {
		$ws->send('{"actions":[{"type":"subscribe","service":"' . $heraldid . '"}]}');

		$ws->listenAsync(			
			sub {
				my $readin = shift;
				main::DEBUGLOG && $log->is_debug && $log->debug("message arrived");
				if (! $self->inboundMetaData($readin))  {
					#unsubscribe and resubscribe to trigger again
					$ws->send('{"actions":[{"type":"unsubscribe","service":"' . $heraldid . '"}]}');
					$ws->send('{"actions":[{"type":"subscribe","service":"' . $heraldid . '"}]}');
				}
			},
			sub {
				$log->warn("Failed to read WebSocket for Track Meta Data");
			},
		);

	}

	return $self;
}


sub trackMetaData {
	my $self = shift;
	my $v   = $self->vars;
	my $connected = 0;

	#Do we have a websocket ?
	if (!$v->{'trackWS'}) {
		$v->{'trackWS'} = Plugins::GlobalPlayerUK::simpleAsyncWS->new('ws://metadata.musicradio.com/v2/now-playing',		
			sub {
					main::DEBUGLOG && $log->is_debug && $log->debug("Connected to track WS");
					$connected = 1;
					
			},
			sub {
				$log->error("Failed to Connect to track web socket");
			}
		);

		if ($connected) {
			$v->{'trackWS'}->send('{"actions":[{"type":"subscribe","service":"' . $v->{'stationId'} . '"}]}');			
			$v->{'trackWS'}->listenAsync(
				sub {
					my $buf = shift;
					main::DEBUGLOG && $log->is_debug && $log->debug("Message received from web socket");					
					$self->inboundTrackMetaData($buf);					
				},
				sub {
						$log->warn("Failed to read WebSocket");
						$v->{'trackWS'}->endListenAsync();
						$v->{'trackWS'}->close();
						$connected = 0;
						$v->{'trackWS'} = 0;
						# start listening to track meta data in 30 seconds
						Slim::Utils::Timers::setTimer($self, time() + 30, \&trackMetaData);
				}
			);
			$self->sendHeartBeat() if $connected;
		} else {
			$log->error("Could not listen for track meta data ");
		}
		
	}
	
	return;
}


sub inboundTrackMetaData {
	my $self = shift;
	my $metaData = shift;
	my $v        = $self->vars;
	my $song  = ${*$self}{'song'};
	my $client = ${*$self}{'client'};

	if ( length($metaData) > 5 ) {
		my $json = decode_json($metaData);
		my $props = $song->pluginData('props');
		
		if ($v->{'tempm3u8'} == 1 && $json->{current_show}->{start} ne $props->{'start'}) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Resetting Props, have the real ones now");
			$props = generateProps($json);
			$song->pluginData( props   => $props );

			my $seconds = str2time($props->{'finish'}) - str2time($props->{'start'});
			my $lastArray = ((int($seconds/CHUNK_SECONDS) * 2 ) ) + 10; #Probably 2 too many, but we want overhang.

			$v->{'lastArr'} = $lastArray;
			$v->{'duration'} = $seconds + CHUNK_SECONDS;
			
			$v->{'m3u8'} = $props->{'m3u8'};
			$v->{'havem3u8'} = 1;
			$v->{'tempm3u8'} = 0;
			$v->{'setTimings'} = 0;			

			$v->{'onlyMaster'} = 1;
		}

		if ( $json->{'now_playing'}->{'type'} eq 'track') {

			my $track = $json->{'now_playing'}->{'title'} . ' by ' . $json->{'now_playing'}->{'artist'};


			main::DEBUGLOG && $log->is_debug && $log->debug("NEW TRACK ...  $track");


			$props->{title} = $json->{'now_playing'}->{'title'};
			$props->{artist} = $json->{'now_playing'}->{'artist'};
			$props->{artwork} =  $json->{'now_playing'}->{'artwork'};

			if ($track ne $v->{'trackData'}) {
				$v->{'trackData'} = $track;

				Slim::Music::Info::setDelayedCallback(
					$client,
					sub {
						$song->pluginData( props   => $props );
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
					},
					'output-only'
				);
			}

		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("Returning to normal");			

			$props->{title} = $props->{'realTitle'};
			$props->{artist} = $props->{'realArtist'};
			$props->{artwork} =  $props->{'realArtwork'};

			my $track = "";

			if ($track ne $v->{'trackData'}) {
				$v->{'trackData'} = $track;

				Slim::Music::Info::setDelayedCallback(
					$client,
					sub {
						$song->pluginData( props   => $props );
						Slim::Control::Request::notifyFromArray( $client, ['newmetadata'] );
					},
					'output-only'
				);
			}
		}

	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("No Json in payload, probably ping");
	}

}


sub sendHeartBeat {
	my $self 	= shift;
	my $v 		= $self->vars;
	main::DEBUGLOG && $log->is_debug && $log->debug("sending ws heartbeat");
	if ($v->{'trackWS'}) {
		$v->{'trackWS'}->send('heartbeat');
	}
	Slim::Utils::Timers::setTimer($self, time() + 30, \&sendHeartBeat);
}


sub inboundMetaData {
	my $self = shift;
	my $metaData = shift;
	my $v        = $self->vars;
	my $song  = ${*$self}{'song'};

	if ( length($metaData) > 5 ) {
		my $json = decode_json($metaData);
		my $props = generateProps($json);
		main::DEBUGLOG && $log->is_debug && $log->debug("we have m3u8 : ". $props->{m3u8});

		if (   (length $props->{m3u8} && !$v->{'isContinue'})
			|| ($v->{'isContinue'} && length $props->{m3u8} && ( $props->{'finish'} ne $v->{'oldFinishTime'}))) {


			my $seconds = str2time($props->{'finish'}) - str2time($props->{'start'});
			my $lastArray = ((int($seconds/CHUNK_SECONDS) * 2 ) ) + 10; #Probably 2 too many, but we want overhang.

			$v->{'lastArr'} = $lastArray;
			$v->{'duration'} = $seconds + CHUNK_SECONDS;
			main::DEBUGLOG && $log->is_debug && $log->debug("Last array : $lastArray duration $seconds");

			$v->{'ws'}->send('{"actions":[{"type":"unsubscribe","service":"' . $v->{'stationId'} . '"}]}');
			$v->{'ws'}->close();

			$v->{'m3u8'} = $props->{m3u8};
			$v->{'havem3u8'} = 1;
			$v->{'tempm3u8'} = 0;
			$v->{'onlyMaster'} = 1;

			$song->pluginData( props   => $props );
			main::DEBUGLOG && $log->is_debug && $log->debug("Closed Initial Web Socket");
			return 1;
		}  else {

			main::DEBUGLOG && $log->is_debug && $log->debug("Creating Temporary m3u8");
			#Let's create a temporary solution so streaming can continue
			my $tempm3u8 = _createTemporarym3u8($props->{m3u8}, $v->{'oldFinishTime'} );


			my $seconds = 7400;
			my $lastArray = ((int($seconds/CHUNK_SECONDS) * 2 ) ) + 10; #Probably 2 too many, but we want overhang.

			$v->{'lastArr'} = $lastArray;
			$v->{'duration'} = $seconds + CHUNK_SECONDS;
			main::DEBUGLOG && $log->is_debug && $log->debug("Last array : $lastArray duration $seconds");

			$v->{'ws'}->send('{"actions":[{"type":"unsubscribe","service":"' . $v->{'stationId'} . '"}]}');
			$v->{'ws'}->close();

			$v->{'m3u8'} = $tempm3u8;
			$v->{'havem3u8'} = 1;
			$v->{'tempm3u8'} = 1;
			$v->{'onlyMaster'} = 1;

			$song->pluginData( props   => $props );
			main::DEBUGLOG && $log->is_debug && $log->debug("Closed Initial Web Socket");

			main::INFOLOG && $log->is_info && $log->info("Old info.  So carry on with guess...");
			return 1;

		}
	} else {
		$log->warn("No Meta Data JSON : Could be server ping");
	}
	return;
}

sub _createTemporarym3u8 {
	my $m3u8 = shift;
	my $oldFinishTime = shift;

	my $newm3u8 = $m3u8;
	my $dt = str2time($oldFinishTime);
	$dt += 7400;

	my $iso8601_string = strftime("%Y-%m-%dT%H:%M:%S+00:00", gmtime($dt));

	my $range = $oldFinishTime . '&playlistEndAt=' . $iso8601_string;
	$newm3u8 =~ s/(playlistStartFrom=).*/$1$range/;
	main::DEBUGLOG && $log->is_debug && $log->debug("Temporary m3u8 : $newm3u8 ");

	return $newm3u8;

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

					if ((!$v->{'isContinue'}) || $v->{'isSeeking'} ) {
						$self->setM3U8Array($epoch);
					} else {
						$v->{'arrayPlace'} = 6;
					}

					#if its the last one in the m3u8 it doesn't give enough time and you get a pause, so adjusting
					if (!$v->{'isSeeking'} && ( $v->{'arrayPlace'} != 6) && (scalar @m3u8arr == ($v->{'arrayPlace'} + 1))) {
						$v->{'arrayPlace'} -= 2;
						main::DEBUGLOG && $log->is_debug && $log->debug("Reducing start point to allow startup");
					}

					$self->setTimings((($v->{'arrayPlace'} - 6) / 2) * CHUNK_SECONDS );
					$v->{'setTimings'} = 1;
					if (!$v->{'isSeeking'} ) {

						# start listening to track meta data in 15 seconds to give time to see programme
						Slim::Utils::Timers::setTimer($self, time() + 15, \&trackMetaData);
					}
					$v->{'firstIn'} = 0;
				}

				if ((!$v->{'setTimings'}) && $v->{'duration'} ) {
					$self->setTimings((($v->{'arrayPlace'} - 6) / 2) * CHUNK_SECONDS );
					$v->{'setTimings'} = 1;
				}

				my $url = _replaceUrl($v->{'m3u8'},$m3u8arr[$v->{'arrayPlace'}]);
				main::DEBUGLOG && $log->is_debug && $log->debug("Now at  $v->{'arrayPlace'} ending at $v->{'lastArr'} ");
				main::DEBUGLOG && $log->is_debug && $log->debug("Getting $url");


				$v->{'arrayPlace'} += 2;

				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: " . length ${ $http->contentRef } . " for $url");

						my %tagshash;
						my $bytesused = Plugins::GlobalPlayerUK::SegmentUtils::getID3frames(\%tagshash,${ $http->contentRef });
						main::DEBUGLOG && $log->is_debug && $log->debug("ID3 Bytes skipped $bytesused");

						my $availbytes = (length(${ $http->contentRef }) - $bytesused);
				
						$v->{'inBuf'} .= substr(${ $http->contentRef }, $bytesused, $availbytes);

						if ($v->{'arrayPlace'} > $v->{'lastArr'}) {
							main::DEBUGLOG && $log->is_debug && $log->debug("Last item end streaming $v->{'lastArr'} ");
							$v->{'streaming'} = 0;
						}
						$v->{'retryCount'} = 0;
						$v->{'fetching'} = 0;
					},

					# Called when no response was received or an error occurred.
					sub {
						$log->warn("error: $_[1]");
						$v->{'retryCount'}++;

						if ($v->{'retryCount'} > RETRY_LIMIT) {
							$log->error("Failed to connect to $url ($_[1]) retry count exceeded ending stream");
							$v->{'streaming'} = 0;
						} else {
							$log->info("Failed to connect to $url ($_[1]) retrying...");
							$v->{'arrayPlace'} -= 2;
						}

						$v->{'fetching'} = 0;

					}
				)->get($url,'User-Agent' => $uaString);
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
			if (!$v->{'fetching'} && $v->{'onlyMaster'}) {
				$v->{'fetching'} = 1;
				_getRealM3u8(
					$v->{'m3u8'},
					sub {
						my $realM3u8 = shift;
						$v->{'m3u8'} = $realM3u8;
						$v->{'onlyMaster'} = 0;
						main::DEBUGLOG && $log->is_debug && $log->debug("Have real m3u8 $realM3u8");
						$v->{'fetching'} = 0;
					},
					sub {
						$log->error("failed to get M3u8 playlist");
						$v->{'fetching'} = 0;
						$v->{'streaming'} = 0;
					}
				);

			} else {
				if ( !$v->{'fetching'} && (!$v->{'m3u8Arr'} || (($v->{'arrayPlace'} > scalar @m3u8arr) && ( ($v->{'lastm3u8'} + $v->{'m3u8Delay'}) < time() ))) )  {
					main::DEBUGLOG && $log->is_debug && $log->debug('Getting Fresh M3u8 ' . Time::HiRes::time());
					$v->{'fetching'} = 1;
					$self->readM3u8(
						$v->{'m3u8'},
						sub {
							my $in=shift;
							main::DEBUGLOG && $log->is_debug && $log->debug('Have Array #' . scalar @{$in});
							$v->{'m3u8Arr'} =$in;
							$v->{'lastm3u8'} = time();

							my @lastCheckArr = @{$v->{'m3u8Arr'}};
							main::DEBUGLOG && $log->is_debug && $log->debug('last item  ' . $lastCheckArr[-1]);

							if ($lastCheckArr[-1] eq END_OF_M3U8) {
								main::DEBUGLOG && $log->is_debug && $log->debug('New last array from ' . $v->{'lastArr'});
								$v->{'lastArr'} = (scalar @lastCheckArr) - 2;
								main::DEBUGLOG && $log->is_debug && $log->debug('setting last array to ' . $v->{'lastArr'});
								if ( $v->{'arrayPlace'} > $v->{'lastArr'} ) {
									main::DEBUGLOG && $log->is_debug && $log->debug('Already got last item, ending streaming');
									$v->{'streaming'} = 0;
								}

							} else {
								if ( $v->{'lastArraySize'} == scalar $v->{'m3u8Arr'} ) {
									main::DEBUGLOG && $log->is_debug && $log->debug('Same array size ' . $v->{'lastArraySize'} );
									$v->{'m3u8Delay'} = 2;
								} else {
									main::DEBUGLOG && $log->is_debug && $log->debug('standard m3u8 wait');
									$v->{'m3u8Delay'} = 9;
								}
								$v->{'lastArraySize'} = scalar $v->{'m3u8Arr'};
							}
							$v->{'fetching'} = 0;

						},
						sub {
							my $connected = shift;
							main::DEBUGLOG && $log->is_debug && $log->debug('No new M3u8 available');
							$v->{'lastm3u8'} = time();
							if ($connected) {
								$v->{'m3u8Delay'} = 1;
							} else {
								$v->{'m3u8Delay'} = 9;
							}
							$v->{'fetching'} = 0;
						}
					);

				}
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

	my $artwork = '';
	if ( $json->{current_show}->{watermarked_artwork} ) {
		$artwork = $json->{current_show}->{watermarked_artwork};
	} else {
		$artwork = $json->{current_show}->{artwork};
	}

	my $props = {
		m3u8 => $json->{current_show}->{live_restart}->{sd_url},
		start => $json->{current_show}->{start},
		finish => $json->{current_show}->{finish},
		title =>  $json->{current_show}->{name},
		realTitle => $json->{current_show}->{name},
		artist => $json->{current_show}->{schedule},
		realArtist =>  $json->{current_show}->{schedule},
		schedule =>  $json->{current_show}->{schedule},
		programmeId =>  $json->{current_show}->{programme_id},
		artwork =>  $artwork,
		realArtwork => $artwork,
	};

	main::DEBUGLOG && $log->is_debug && $log->debug('Props : ' . Dumper($props));
	return $props;

}


sub readM3u8 {
	my ( $self, $m3u8, $cbY, $cbN ) = @_;

	my $v = $self->vars;


		Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${ $http->contentRef };

			my @m3u8arr = split /\n/, $content;
			main::DEBUGLOG && $log->is_debug && $log->debug('m3u8 array size : ' . scalar @m3u8arr);

			$cbY->(\@m3u8arr);
		},
		sub {

			$log->error("Could not get audio ");
			$cbN->(0);

		}
	)->get($m3u8,  'User-Agent' => $uaString );

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
				artist => $props->{'artist'},
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
		} elsif ( $uri =~ /_schedulecatchup_/gm) {
			my $id = _getItemId($uri);
			Plugins::GlobalPlayerUK::GlobalPlayerFeeder::getCatchupStreamUrl(
				$id,
				sub {
					my $stream = shift;

					if ($main::VERSION lt '8.2.0') {
						$cb->([$stream->{url}]);
					} else {


						my $ret ={
							'type'  => 'opml',
							'title' => '',
							'items' => [$stream]
						};

						$cb->($ret);
					}
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


sub _getRealM3u8 {
	my $parent = shift;
	my $cbY = shift;
	my $cbN = shift;


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $content = ${ $http->contentRef };
			my @m3u8arr = split /\n/, $content;

			my $m3u8 = $m3u8arr[3];
			my $newm3u8 = _replaceUrl($parent, $m3u8);

			main::DEBUGLOG && $log->is_debug && $log->debug("New m3u8 = $newm3u8 ");
			$cbY->($newm3u8);

		},# Called when no response was received or an error occurred.
		sub {
			$log->error("Could not get audio ");
			$cbN->();

		}
	)->get($parent, 'User-Agent' => $uaString);


}


sub _replaceUrl {
	my $inUrl = shift;
	my $rep = shift;

	my @urlsplit = split('/', $inUrl);
	$urlsplit[-1] = $rep;
	my $newurl = join('/', @urlsplit );

	return $newurl;
}

1;