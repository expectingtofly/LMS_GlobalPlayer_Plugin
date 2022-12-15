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

use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Plugins::GlobalPlayerUK::GlobalPlayerFeeder;
use Plugins::GlobalPlayerUK::WebSocketHandler;

Slim::Player::ProtocolHandlers->registerHandler('globalplayer', __PACKAGE__);

my $log = logger('plugin.globalplayeruk');


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
		} elsif ( $uri =~ /_live_/ ) {

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