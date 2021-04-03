package Plugins::GlobalPlayerUK::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.globalplayeruk');

sub name {
    return 'PLUGIN_GLOBALPLAYERUK';
}

sub page {
    return 'plugins/GlobalPlayerUK/settings/basic.html';
}

sub prefs {  
    return ( $prefs, qw(is_radio) );
}

1;