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

Slim::Player::ProtocolHandlers->registerHandler('globalplayer', __PACKAGE__);

my $log = logger('plugin.globalplayeruk');


sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	$log->debug("Entering with $uri");

	if ( $uri =~ /^globalplayer:/gm ) {
		$log->debug("In 1");
		if ( $uri =~ /_playlist_/gm){
			$log->debug("In 2");
			my $id = _getItemId($uri);
			Plugins::GlobalPlayerUK::GlobalPlayerFeeder::getPlaylistStreamUrl(
				$id,
				sub {
					my $stream = shift;

					$log->debug("In 3 $stream");
					$cb->([$stream]);
				},
				sub {
					$log->error("Failed to get playlist stream URL");
					$cb->([$uri]);
				}
			);
		} else {
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