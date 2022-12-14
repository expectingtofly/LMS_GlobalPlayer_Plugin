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

use POSIX qw(strftime);
use HTTP::Date;

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
	main::DEBUGLOG && $log->is_debug && $log->debug("++callAPI");

	my $call = $passDict->{'call'};
	my $callUrl = '';
	my $parser;
	my $cacheIndex = '';

	if ($call eq 'LiveMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/globalplayer/brands';
		$parser = \&_parseStationList;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'RegionalLiveMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/stations/';
		$parser = \&_parseFullStationList;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'PlaylistMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/features/playlists';
		$parser = \&_parsePlaylistDetails;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'PodcastMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/features/podcasts';
		$parser = \&_parsePodcastDetails;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'CatchUpMenu') {
		$callUrl = 'https://bff-web-guacamole.musicradio.com/globalplayer/brands';
		$parser = \&_parseCatchUpStationList;
		$cacheIndex =  $call;
	} elsif ($call eq 'StationCatchUps') {
		my $station    = $passDict->{'station'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/globalplayer/catchups/$station/uk";
		$parser = \&_parseCatchUpList;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'StationCatchupItems') {
		my $id    = $passDict->{'id'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/globalplayer/catchups/$id";
		$parser = \&_parseCatchUpEpisodes;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'PodcastEpisodes') {
		my $id    = $passDict->{'id'};
		$callUrl = "https://bff-web-guacamole.musicradio.com/podcasts/$id/";
		$parser = \&_parsePodcastEpisodes;
		$cacheIndex =  $callUrl;
	} elsif ($call eq 'PodcastSearch') {
		my $searchstr = $args->{'search'};
		$callUrl = 'https://bff-web-guacamole.musicradio.com/podcasts/search/?query=' . URI::Escape::uri_escape_utf8($searchstr);
		$parser = \&_parsePodcastSearchResults;
		$cacheIndex =  $callUrl;
	} else {
		$log->error("No API call for $call");
		return;
	}

	if (my $menu = _getCachedMenu($cacheIndex)) {
		main::INFOLOG && $log->is_info && $log->info("Getting Menu from cache for $cacheIndex");
		_renderMenuCodeRefs($menu);
		$callback->( { items => $menu } );
		return;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("call URL $callUrl");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			$parser->( $http, $callback, $cacheIndex );
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->( [ { name => $_[1], type => 'text' } ] );
		}
	)->get($callUrl);
	main::DEBUGLOG && $log->is_debug && $log->debug("--callAPI");
	return;
}


sub _parseCatchUpEpisodes {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseCatchUpEpisodes");

	my $JSON = decode_json ${ $http->contentRef };

	my $episodes = $JSON->{episodes};

	my $menu = [];

	for my $item (@$episodes) {
		my $stdat = str2time( $item->{'startDate'} );
		my $strfdte = strftime( '%A %d/%m ', localtime($stdat) );
		my $title = $strfdte . $item->{title} . ' - ' . $item->{description};


		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{imageUrl},
			on_select   => 'play'
		  };
	}
	_cacheMenu($cacheIndex, $menu, 600);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseCatchUpEpisodes");
	return;
}


sub _parsePodcastEpisodes {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePodcastEpisodes");

	my $ctnt = ${ $http->contentRef };
	$log->debug("episodes : $ctnt");
	my $JSON = decode_json $ctnt;

	my $episodes = $JSON->{episodes};

	my $menu = [];

	for my $item (@$episodes) {

		my $stdat = str2time( $item->{'pubDate'} );
		my $strfdte = strftime( '%d/%m/%y ', localtime($stdat) );
		my $title = $strfdte . $item->{title};
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{imageUrl},
			on_select   => 'play'
		  };
	}
	_cacheMenu($cacheIndex, $menu, 600);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePodcastEpisodes");
	return;
}


sub _parsePlaylistDetails {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePlaylistDetails");

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
	_cacheMenu($cacheIndex, $menu, 600);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePlaylistDetails");
	return;
}


sub _parsePodcastSearchResults {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePodcastSearchResults");

	my $JSON = decode_json ${ $http->contentRef };

	my $podcasts = $JSON->{podcasts};

	my $menu = [];

	for my $item (@$podcasts) {
		my $title = $item->{title};
		push  @$menu,
		  {
			name => $title,
			type => 'link',
			url         => \&callAPI,
			image => $item->{imageUrl},
			favorites_url => 'globalplayer://_podcast_' . $item->{id},
			favorites_type	=> 'link',
			playlist => 'globalplayer://_podcast_' . $item->{id},
			passthrough =>[ { call => 'PodcastEpisodes', id => $item->{id}, codeRef => 'callAPI' } ]
		  };
	}
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePodcastSearchResults");
	return;
}


sub _parsePodcastDetails {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePodcastDetails");

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	push @$menu,{

		name        => 'Podcast Search',
		type        => 'search',
		url         => '',
		passthrough => [ { call => 'PodcastSearch', codeRef => 'callAPI' } ]

	};

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

	_cacheMenu($cacheIndex, $menu, 600);
	_renderMenuCodeRefs($menu);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePodcastDetails");
	return;
}


sub _parsePlaylistItems {
	my ($items) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePlaylistItems");

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
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePlaylistItems");
	return $menu;
}


sub _parsePodcastItems {
	my ($items) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parsePodcastItems");

	my $menu = [];

	for my $item (@$items) {
		my $title = $item->{title} . ' - ' . $item->{subtitle};
		push  @$menu,
		  {
			name => $title,
			type => 'link',
			url         => '',
			image => $item->{image_url},
			favorites_url => 'globalplayer://_podcast_' . $item->{link}->{id},
			favorites_type	=> 'link',
			playlist => 'globalplayer://_podcast_' . $item->{link}->{id},
			passthrough =>[ { call => 'PodcastEpisodes', id => $item->{link}->{id}, codeRef => 'callAPI' } ]
		  };
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parsePodcastItems");
	return $menu;
}


sub _parseStationList {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseStationList");

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		my $tagline = '';
		if (length $item->{tagline}) {
			$tagline = ' - ' . $item->{tagline};
		}
		my $title = $item->{name} . $tagline;
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},
			image => $item->{brandLogo},
			on_select   => 'play'
		  };
	}
	push  @$menu,
	  {
		name => 'Full Regional Radio',
		type => 'link',
		url => '',
		image => Plugins::GlobalPlayerUK::Utilities::IMG_RADIO,
		passthrough =>[ { call => 'RegionalLiveMenu', codeRef => 'callAPI'} ]
	  };
	_cacheMenu($cacheIndex, $menu, 600);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseStationList");
	return;
}


sub _parseFullStationList {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseFullStationList");
	
	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		my $tagline = '';
		if (length $item->{tagline}) {
			$tagline = ' - ' . $item->{tagline};
		}
		my $title = $item->{name} . $tagline;
		push  @$menu,
		  {
			name => $title,
			type => 'audio',
			url         => $item->{streamUrl},			
			on_select   => 'play'
		  };
	}

	_cacheMenu($cacheIndex, $menu, 600);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseFullStationList");
	return;
}


sub _parseCatchUpList {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseCatchUpList");

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		push  @$menu,
		  {
			name => $item->{title},
			type => 'link',
			url         => '',
			image => $item->{imageUrl},
			favorites_url => 'globalplayer://_catchup_' . $item->{id},
			favorites_type	=> 'link',
			playlist => 'globalplayer://_catchup_' . $item->{id},
			passthrough =>[ { call => 'StationCatchupItems', id => $item->{id}, codeRef => 'callAPI'} ]
		  };
	}
	_cacheMenu($cacheIndex, $menu, 600);
	_renderMenuCodeRefs($menu);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseCatchUpList");
	return;
}


sub _parseCatchUpStationList {
	my ( $http, $callback, $cacheIndex ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseCatchUpStationList");

	my $JSON = decode_json ${ $http->contentRef };

	my $menu = [];

	for my $item (@$JSON) {
		push  @$menu,
		  {
			name => $item->{name},
			type => 'link',
			url         => '',
			image => $item->{brandLogo},
			passthrough =>[ { call => 'StationCatchUps', station => $item->{brandSlug},  codeRef => 'callAPI'} ]
		  };
	}
	_cacheMenu($cacheIndex, $menu, 600);
	_renderMenuCodeRefs($menu);
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseCatchUpStationList");
	return;
}


sub getPlaylistStreamUrl {
	my ( $id, $cbY, $cbN ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getPlaylistStreamUrl");

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

	main::DEBUGLOG && $log->is_debug && $log->debug("--getPlaylistStreamUrl");
	return;
}


sub _getCachedMenu {
	my ($url) = @_;
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


sub _renderMenuCodeRefs {
	my $menu = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_renderMenuCodeRefs");

	for my $menuItem (@$menu) {
		my $codeRef = $menuItem->{passthrough}[0]->{'codeRef'};
		if ( defined $codeRef ) {
			if ( $codeRef eq 'callAPI' ) {
				$menuItem->{'url'} = \&callAPI;
			}else {
				$log->error("Unknown Code Reference : $codeRef");
			}
		}
		if (defined $menuItem->{'items'}) {
			_renderMenuCodeRefs($menuItem->{'items'});
		}

	}
	main::DEBUGLOG && $log->is_debug && $log->debug("--_renderMenuCodeRefs");
	return;
}

1;
