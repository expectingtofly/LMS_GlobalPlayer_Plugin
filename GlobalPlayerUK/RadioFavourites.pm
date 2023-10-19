package Plugins::GlobalPlayerUK::RadioFavourites;

# Copyright (C) 2021 Stuart McLean stu@expectingtofly.co.uk

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

use Slim::Utils::Log;
use JSON::XS::VersionOneAndTwo;
use HTTP::Date;
use Data::Dumper;

use Plugins::GlobalPlayerUK::WebSocketHandler;

my $log = logger('plugin.globalplayeruk');


sub getStationData {
	my ( $stationUrl, $stationKey, $stationName, $nowOrNext, $cbSuccess, $cbError) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getStationData");

	if ($nowOrNext eq 'next') {
		$log->error('Next not supported');
		$cbError->(
			{
				url       => $stationUrl,
				stationName => $stationName
			}
		);
		return;
	}

	my $ws = Plugins::GlobalPlayerUK::WebSocketHandler->new();
	$ws->wsconnect(
		'wss://metadata.musicradio.com/v2/now-playing',
		sub {#success
			main::DEBUGLOG && $log->is_debug && $log->debug("Connected to WS");
			$ws->wssend('{"actions":[{"type":"subscribe","service":"' . $stationKey . '"}]}');
			$ws->wsreceive(
				0.2,
				sub {
					main::DEBUGLOG && $log->is_debug && $log->debug("Read succeeded");
				},
				sub {
					$log->warn("Failed to read WebSocket");
					$cbError>();
				}
			);
		},
		sub {#fail
			my $result = shift;
			$log->warn("Failed to connect to WebSocket : $result");
			$cbError->();
		},
		sub {#Read
			my $readin = shift;
			main::DEBUGLOG && $log->is_debug && $log->debug("read WS : $readin");
			my $json = decode_json($readin);
			$ws->wssend('{"actions":[{"type":"unsubscribe","stream_id":"' . $stationKey . '"}]}');
			$ws->wsclose();
			my $result = {
				title =>  $json->{current_show}->{name},
				description => '',
				image => $json->{current_show}->{watermarked_artwork},
				startTime => str2time($json->{current_show}->{start}),
				endTime   => str2time($json->{current_show}->{finish}),
				url       => $stationUrl,
				stationName => $stationName
			};
			$cbSuccess->($result);
		}
	);
	return;
}

1;

