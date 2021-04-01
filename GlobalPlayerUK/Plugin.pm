package Plugins::GlobalPlayerUK::Plugin;

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

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::GlobalPlayerUK::GlobalPlayerFeeder;

my $log = Slim::Utils::Log->addLogCategory(
	{
		'category'     => 'plugin.globalplayeruk',
		'defaultLevel' => 'WARN',
		'description'  => getDisplayName(),
	}
);


sub initPlugin {
	my $class = shift;


	$class->SUPER::initPlugin(
		feed   => \&Plugins::GlobalPlayerUK::GlobalPlayerFeeder::toplevel,
		tag    => 'globalplayeruk',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);


	return;
}


sub getDisplayName { return 'PLUGIN_GLOBALPLAYERUK'; }

1;
