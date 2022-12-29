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


use Plugins::GlobalPlayerUK::GlobalPlayerFeeder;
use Plugins::GlobalPlayerUK::WebSocketHandler;

use constant MIN_OUT    => 8192;
use constant DATA_CHUNK => 128 * 1024;
use constant CHUNK_SECONDS => 10;


Slim::Player::ProtocolHandlers->registerHandler('globalplayer', __PACKAGE__);

my $log = logger('plugin.globalplayeruk');

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


	return 1;
}


# fetch the Sounds player url and extract a playable stream
sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("getNextTrack++");

	my $masterUrl = $song->track()->url;
	my $isContinue = 0;
	my $oldm3u8 = '';

	main::INFOLOG && $log->is_info && $log->info("Request for next track " . $masterUrl);

	if (my $props = $song->pluginData('props')) {
		main::INFOLOG && $log->is_info && $log->info("We are need to continue here");
		$oldm3u8 = $props->{m3u8};
		$isContinue = 1;
	}

	getm3u8Arr(
		$masterUrl,
		sub {
			my $in = shift;
			my $json = shift;
			my @m3u8arr= @{$in};

			my $firstStream = $m3u8arr[7];
			my $props = generateProps($json, $isContinue);
			$props->{m3u8arr} = $in;
			$props->{m3u8Pos} = 7;
			$props->{isContinue} = $isContinue;

			if ( $isContinue && ($props->{m3u8} eq $oldm3u8)) {
				main::DEBUGLOG && $log->is_debug && $log->debug("m3u8 still the same");
				my $oldm3u8 = incrementM3u8($oldm3u8);
				$props = {
					isContinue => $isContinue,
					m3u8 => $oldm3u8,
				};
			}

			$song->pluginData( props   => $props );
			main::DEBUGLOG && $log->is_debug && $log->debug("First Stream $firstStream");
			$song->streamUrl($firstStream);
			$successCb->();

		},
		$errorCb
	);

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
			$log->warn("Failed to connect to WebSocket");
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
	${*$self}{'vars'}->{'session'}->disconnect;

	main::INFOLOG && $log->is_info && $log->info('close called');


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

	main::INFOLOG && $log->is_info && $log->info('starting ' . ((scalar @arr) - 1));
	for ( my $i = ((scalar @arr) - 1) ; $i >= 7 ; $i -= 2 ) {
		main::INFOLOG && $log->is_info && $log->info('comparing ' . substr($arr[$i],-19) . ' and ' . $fulltime);
		if (substr($arr[$i],-19) lt $fulltime) {
			main::INFOLOG && $log->is_info && $log->info('Found it ' . $i . ' had ' . $arr[$i] . ' and ' . $fulltime);
			$v->{'arrayPlace'} = $i;
			return;
		}
		main::INFOLOG && $log->is_info && $log->info('Not Found it ' . $i);
	}
	main::INFOLOG && $log->is_info && $log->info('Never Found it ');
	return;
}


sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	main::INFOLOG && $log->info( 'Trying to seek ' . $newtime . ' seconds for offset ' . $song->track->audio_offset );

	return { timeOffset => $newtime };
}


sub setTimings {
	my $self = shift;
	my $secondsIn = shift;
	my $v        = $self->vars;
	my $client = ${*$self}{'client'};
	my $song     = ${*$self}{'song'};

	main::INFOLOG && $log->is_info && $log->info("Setting to $secondsIn ");


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


	my $client = $args->{client};
	my $masterUrl = $song->track()->url;
	my $streamUrl = $song->streamUrl() || return;
	main::INFOLOG && $log->is_info && $log->info('Remote streaming  : ' . $streamUrl . ' actual url ' . $masterUrl);

	my $self = $class->SUPER::new;


	main::INFOLOG && $log->is_info && $log->info('set up vars ...');

	my $seconds = str2time($props->{'finish'}) - str2time($props->{'start'});

	my $lastArray = ((int($seconds/CHUNK_SECONDS) * 2 ) - 4) + 7;
	main::INFOLOG && $log->is_info && $log->info("last array $lastArray");
	my $ws;
	if ($props->{isContinue} && !(defined $props->{m3u8arr})) {
		main::INFOLOG && $log->is_info && $log->info("we dont have the details yet. create a web socket session");
		my $heraldid = _getItemId($masterUrl);
		$ws = Plugins::GlobalPlayerUK::WebSocketHandler->new();
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
				$log->warn("Failed to connect to WebSocket");
			},
			sub {#Read
				my $readin = shift;
				main::DEBUGLOG && $log->is_debug && $log->debug("read WS : $readin");
				my $json = decode_json($readin);
				my $checkProps = generateProps($json);

				main::DEBUGLOG && $log->is_debug && $log->debug("we have m3u8 1: ". $props->{m3u8} . " and 2: " . $checkProps->{m3u8} );

				if ($checkProps->{m3u8} eq $props->{m3u8}) {
					$ws->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $heraldid . '"}]}');
					$ws->wsclose();
					$song->pluginData( props   => $checkProps );
					my $secs = str2time($checkProps->{'finish'}) - str2time($checkProps->{'start'});
					${*$self}{'vars'}->{'duration'} =  $secs;
					${*$self}{'vars'}->{'lastArr'} = ((int($secs/CHUNK_SECONDS) * 2 ) - 4) + 7;
				}
			}
		);

	}


	${*$self}{contentType} = 'aac';
	${*$self}{'song'}   = $args->{'song'};
	${*$self}{'client'} = $args->{'client'};
	${*$self}{'url'}    = $args->{'url'};
	${*$self}{'vars'} = {    # variables which hold state for this instance:
		'inBuf'  => '',      # buffer of received data
		'outBuf' => '',      # buffer of processed audio
		'streaming' =>1,    # flag for streaming, changes to 0 when all data received
		'fetching' => 0,        # waiting for HTTP data
		'firstIn' => 1,        # waiting for HTTP data
		'arrayPlace'   => $props->{m3u8Pos}, # where in array to start
		'm3u8Arr' => $props->{m3u8arr}, #m3u8 array
		'm3u8' => $props->{m3u8},
		'duration' => $seconds,
		'lastm3u8' => 0,
		'lastArr' => $lastArray,
		'session' 	  => Slim::Networking::Async::HTTP->new,
		'baseURL'	  => $args->{'url'},
		'isContinue' => $props->{isContinue},
		'setTimings' => 0,
		'headers'	=> 0,
		'ws' => $ws,
	};

	return $self;
}


sub sysread {
	use bytes;

	my $self = $_[0];

	# return in $_[1]
	my $maxBytes = $_[2];
	my $v        = $self->vars;
	my $props    = ${*$self}{'props'};
	my $song      = ${*$self}{'song'};
	my $masterUrl = $song->track()->url;

	my @m3u8arr = ();

	if ($v->{'m3u8Arr'}) {
		@m3u8arr = @{$v->{'m3u8Arr'}};

		# need more data
		# need more data
		if (   length $v->{'outBuf'} < MIN_OUT
			&& !$v->{'fetching'}
			&& $v->{'streaming'}
			&& ($v->{'arrayPlace'} < scalar @m3u8arr ) ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Getting more data");
			$v->{'fetching'} = 1;

			if ( $v->{'firstIn'} ) {
				if ($v->{'isContinue'} ) {
					main::DEBUGLOG && $log->is_debug && $log->debug("Continue, setting to 7");
					$v->{'arrayPlace'} = 7;

					if ($v->{'duration'}) {
						$self->setTimings(0);
						$v->{'setTimings'} = 1;
					}

				} else {

					#Find starting point
					my $liveTime = strftime( '%Y%m%d_%H%M%S', localtime(time() - 50) );
					main::DEBUGLOG && $log->is_debug && $log->debug("Current Live Time : $liveTime ");
					$self->setM3U8Array($liveTime);
					$self->setTimings((($v->{'arrayPlace'} - 7) / 2) * 10 );
					$v->{'setTimings'} = 1;
				}
				$v->{'firstIn'} = 0;
			}
			if (!$v->{'duration'} ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("No duration yet, call ws");
				$v->{'ws'}->wsreceive(
					0.1,
					sub {
						main::DEBUGLOG && $log->is_debug && $log->debug("Read succeeded");
					},
					sub {
						$log->warn("Failed to read WebSocket");
					}
				);
			}
			if ((!$v->{'setTimings'}) && $v->{'duration'} ) {
				$self->setTimings((($v->{'arrayPlace'} - 7) / 2) * 10 );
				$v->{'setTimings'} = 1;
			}


			my $url = $m3u8arr[$v->{'arrayPlace'}];
			main::DEBUGLOG && $log->is_debug && $log->debug("Now at  $v->{'arrayPlace'} ending at $v->{'lastArr'} ");
			if ($v->{'arrayPlace'} == $v->{'lastArr'}) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Last item end streaming $v->{'lastArr'} ");
				$v->{'streaming'} = 0;

			}
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

						main::DEBUGLOG && $log->is_debug && $log->debug("have dechunked");
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


	# process all available data
	if ( length $v->{'inBuf'} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Procesing In Buf');
		$v->{'outBuf'} .=   $v->{'inBuf'};
		$v->{'inBuf'} = '';
	}
	if (my $bytes = min( length $v->{'outBuf'}, $maxBytes ) ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Bytes . ' . $maxBytes . ' . ' . length $v->{'outBuf'});
		$_[1] = substr( $v->{'outBuf'}, 0, $bytes, '' );

		return $bytes;
	} elsif ( $v->{'streaming'} ) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No bytes available' . Time::HiRes::time());
		if ( !$v->{'m3u8Arr'} || (($v->{'arrayPlace'} > scalar @m3u8arr) && (!$v->{'fetching'}) && ( $v->{'lastm3u8'} + 9 < time() ) ))  {
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
					$v->{'fetching'} = 0;
					$v->{'headers'} = $headers;
				},
				sub {
					main::DEBUGLOG && $log->is_debug && $log->debug('No new M3u8 available');
					$v->{'lastm3u8'} = time();
					$v->{'fetching'} = 0;
				},
				$v->{'headers'},
			);

		}

		$! = EINTR;
		return undef;
	}

	# end of streaming and make sure timer is not running
	main::INFOLOG && $log->is_info && $log->info("end streaming");
	$props->{'updatePeriod'} = 0;

	return 0;
}


sub generateProps {
	my $json = shift;

	my $props = {
		m3u8 => $json->{current_show}->{live_restart_url},
		start => $json->{current_show}->{start},
		finish => $json->{current_show}->{finish},
		title =>  $json->{current_show}->{name},
		schedule =>  $json->{current_show}->{schedule},
		programmeId =>  $json->{current_show}->{programme_id},
		artwork =>  $json->{current_show}->{artwork},

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
					$cbN->();						
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
				$cbN->();	
				
			}
		}
	);

	return;
}


sub incrementM3u8 {
	my $inUrl = shift;

	my $outUrl = $inUrl;

	my @urlArr = split /\//, $inUrl;
	my $lastPart = $urlArr[-1];

	my @finalArr = split /\./, $lastPart;
	my $progNo = int($finalArr[0]);
	$progNo++;
	my $sProgNo = "$progNo";
	$outUrl =~ s/$finalArr[0]/$sProgNo/;

	main::DEBUGLOG && $log->is_debug && $log->debug("oldm3u8: $inUrl newm3ui: $outUrl");
	return $outUrl;
}


sub getMetadataFor {
	my ( $class, $client, $full_url ) = @_;

	my ($url) = $full_url =~ /([^&]*)/;
	my $song = $client->playingSong();

	main::DEBUGLOG && $log->is_debug && $log->debug("getmetadata: $url");

	my $meta = {title => $url};
	if ( $song && $song->currentTrack()->url eq $full_url ) {
		if (my $props = $song->pluginData('props') ) {
			$meta = {
				title => $props->{'title'},
				cover => $props->{'artwork'},
				artist => $props->{'schedule'},
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
		} elsif ( $uri =~ /_liv_/ ) {

			$log->debug("Doing Live");
			my $heraldid = _getItemId($uri);
			$log->debug("herald id $heraldid");

			my $ws = Plugins::GlobalPlayerUK::WebSocketHandler->new();
			$log->debug("have object");

			$ws->wsconnect(
				'wss://metadata.musicradio.com/v2/now-playing',
				sub {#success
					$log->error("Connected");
					$ws->wssend('{"actions":[{"type":"subscribe","service":"' . $heraldid . '"}]}');
					$log->error("Initiate read");
					$ws->wsreceive(
						0.2,
						sub {
							$log->error("Read succeeded");
						},
						sub {
							$log->error("Read failed");
						}
					);
				},
				sub {#fail
					$log->error("Failed to connect to web socket");
				},
				sub {#Read
					my $readin = shift;
					$log->error("We have read ". $readin);
					$ws->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $heraldid . '"}]}');
					$ws->wsclose();
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