package Plugins::GlobalPlayerUK::GlobalPlayerFeeder;

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

use URI::Escape;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Cache;

use Data::Dumper;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);

use Plugins::GlobalPlayerUK::Utilities;


my $log = logger('plugin.globalplayeruk');
my $prefs = preferences('plugin.globalplayeruk');

my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");


	my $menu = [
		{
			name => 'Radio',
			type => 'link',
			url => \&callAPI,
			image => Plugins::GlobalPlayerUK::Utilities::IMG_RADIO,
			passthrough =>[ { call => 'LiveMenu' } ]
		},
		{
			name => 'Catch Up',
			type => 'link',
			url  => \&callAPI,
			image => Plugins::GlobalPlayerUK::Utilities::IMG_CATCHUP,
			passthrough =>[ { call => 'CatchUpMenu' } ]
		},
		{
			name => 'Playlists',
			type => 'link',
			url  => \&callAPI,
			image => Plugins::GlobalPlayerUK::Utilities::IMG_PLAYLISTS,
			passthrough =>[ { call => 'PlaylistMenu' } ]
		},
		{
			name => 'Podcasts',
			type => 'link',
			url  => \&callAPI,
			image => Plugins::GlobalPlayerUK::Utilities::IMG_PODCASTS,
			passthrough =>[ { call => 'PodcastMenu' } ]
		}
	];

	$callback->( { items => $menu } );
	return;
}


sub callAPI {
	my ( $client, $callback, $args, $passDict ) = @_;

	my $call = $passDict->{'call'};
	my $callUrl = '';
	my $parser;

	if ($call eq 'LiveMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/globalplayer/brands';
		$parser = \&_parseStationList;
	} elsif ($call eq 'PlaylistMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/features/playlists';
		$parser = \&_parsePlaylistDetails;
	} elsif ($call eq 'PodcastMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/features/podcasts';
		$parser = \&_parsePodcastDetails;	
	} elsif ($call eq 'CatchUpMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/globalplayer/brands';;
		$parser = \&_parseCatchUpStationList;
	} elsif ($call eq 'StationCatchUps') {
		my $station    = $passDict->{'station'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/globalplayer/catchups/$station/uk";
		$parser = \&_parseCatchUpList;	
	} elsif ($call eq 'StationCatchupItems') {
		my $id    = $passDict->{'id'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/globalplayer/catchups/$id";
		$parser = \&_parseCatchUpEpisodes;
	} elsif ($call eq 'PodcastEpisodes') {
		my $id    = $passDict->{'id'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/podcasts/$id/";
		$parser = \&_parsePodcastEpisodes;
	} else {
		$log->error("No API call for $call");
		return;
	}


	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			$parser->( $http, $callback );
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->( [ { name => $_[1], type => 'text' } ] );
		}
	)->get($callUrl);
	return;
}

sub _parseCatchUpEpisodes {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $episodes = $JSON->{episodes};

	my $menu = [];

	for my $item (@$episodes) {
		my $title = $item->{title} . ' - ' . $item->{description};
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{imageUrl},
			on_select   => 'play'
		  };
	}
	$callback->( { items => $menu } );
	return;
}


sub _parsePodcastEpisodes {
	my ( $http, $callback ) = @_;

	my $ctnt = ${ $http->contentRef };
	$log->debug("episodes : $ctnt");
	my $JSON = decode_json $ctnt;

	my $episodes = $JSON->{episodes};

	my $menu = [];

	for my $item (@$episodes) {
		my $title = $item->{title} . ' - ' . $item->{description};
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{imageUrl},
			on_select   => 'play'
		  };
	}
	$callback->( { items => $menu } );
	return;
}


sub _parsePlaylistDetails {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $blocks = $JSON->{blocks};

	my $menu = [];

	for my $item (@$blocks) {
		my $title = $item->{title};
		my $items = _parsePlaylistItems($item->{items});
		push  @$menu,
		  {
			name => $item->{title},
			type => 'link',
			items => $items
		  };
	}
	$callback->( { items => $menu } );
	return;
}


sub _parsePodcastDetails {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	my $loop = sub {
		my $blocks = shift;
		for my $item (@$blocks) {
			my $title = $item->{title};
			my $items = _parsePodcastItems($item->{items});
			push  @$menu,
			  {
				name => $item->{title},
				type => 'link',
				items => $items
			  };
		}
	};

	$loop->([$JSON->{heroBlock}]);
	$loop->($JSON->{blocks});

	$callback->( { items => $menu } );
	return;
}


sub _parsePlaylistItems {
	my ($items) = @_;

	my $menu = [];

	for my $item (@$items) {
		my $stream = 'globalplayer://_playlist_' . $item->{link}->{id};
		push  @$menu,
		  {
			name => $item->{title},
			type => 'playlist',
			url     => $stream,
			image => $item->{image_url},
			on_select   => 'play'
		  };
	}

	return $menu;
}


sub _parsePodcastItems {
	my ($items) = @_;

	my $menu = [];

	for my $item (@$items) {
		my $title = $item->{title} . ' - ' . $item->{subtitle};
		push  @$menu,
		  {
			name => $title,
			type => 'link',
			url         => \&callAPI,
			image => $item->{image_url},
			passthrough =>[ { call => 'PodcastEpisodes', id => $item->{link}->{id} } ]
		  };
	}

	return $menu;
}


sub _parseStationList {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		my $title = $item->{name} . ' - ' . $item->{tagline};
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{brandLogo},
			on_select   => 'play'
		  };
	}
	$callback->( { items => $menu } );
	return;
}


sub _parseCatchUpList {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		push  @$menu,
		  {
			name => $item->{title},
			type => 'link',
			url         => \&callAPI,
			image => $item->{imageUrl},
			passthrough =>[ { call => 'StationCatchupItems', id => $item->{id}} ]
		  };
	}
	$callback->( { items => $menu } );
	return;
}


sub _parseCatchUpStationList {
	my ( $http, $callback ) = @_;

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		push  @$menu,
		  {
			name => $item->{name},
			type => 'link',
			url         => \&callAPI,
			image => $item->{brandLogo},
			passthrough =>[ { call => 'StationCatchUps', station => $item->{brandSlug}} ]
		  };
	}
	$callback->( { items => $menu } );
	return;
}

sub getPlaylistStreamUrl {
	my ( $id, $cbY, $cbN ) = @_;

	my $callUrl = "https://bff-web-guacamole.musicradio.com/playlists/$id";

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $JSON = decode_json ${ $http->contentRef };
			$cbY->($JSON->{streamUrl});
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$cbN->();
		}
	)->get($callUrl);

	return;
}


sub _getCachedMenu {
	my ( $url ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getCachedMenu");

	my $cacheKey = 'GP:' . md5_hex($url);

	if ( my $cachedMenu = $cache->get($cacheKey) ) {
		my $menu = ${$cachedMenu};
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu got cached menu");
		return $menu;
	}else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu no cache");
		return;
	}
}


sub _cacheMenu {
	my ( $url, $menu, $seconds ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_cacheMenu");
	my $cacheKey = 'GP:' . md5_hex($url);
	$cache->set( $cacheKey, \$menu, $seconds );

	main::DEBUGLOG && $log->is_debug && $log->debug("--_cacheMenu");
	return;
}


1;
