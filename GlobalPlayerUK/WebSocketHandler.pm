package Plugins::GlobalPlayerUK::WebSocketHandler;


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

#!/usr/bin/env perl
use warnings;
use strict;


use IO::Socket::SSL;
use IO::Select;
use Protocol::WebSocket::Client;

use Data::Dumper;

use Slim::Utils::Log;

my $log = logger('plugin.globalplayeruk');


sub new {
	my $class = shift;
	my $self = {};
	my $self = {
		client     => 0,         
		tcp_socket   => 0,       
	};
	
	bless $self, $class;
	return $self;
}


sub wsconnect {
	my ( $self, $url, $cbConnected, $cbConnectFailed, $cbRead ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("++connect");
	my ($proto, $host, $port, $path);
	if ($url =~ m/^(?:(?<proto>ws|wss):\/\/)?(?<host>[^\/:]+)(?::(?<port>\d+))?(?<path>\/.*)?$/){
		$host = $+{host};
		$path = $+{path};
		if (defined $+{proto} && defined $+{port}) {
			$proto = $+{proto};
			$port = $+{port};
		} elsif (defined $+{port}) {
			$port = $+{port};
			if ($port == 443) { $proto = 'wss' }
			else { $proto = 'ws' }
		} elsif (defined $+{proto}) {
			$proto = $+{proto};
			if ($proto eq 'wss') { $port = 443 }
			else { $port = 80 }
		} else {
			$proto = 'ws';
			$port = 80;
		}
	} else {
		$log->warn("Failed to parse $url");
		$cbConnectFailed->("Failed to parse Host/Port from URL.");
	}

	main::INFOLOG && $log->is_info && $log->info("Attempting to open SSL socket to $proto://$host:$port...");

	$self->{tcp_socket} = IO::Socket::SSL->new(
		PeerAddr => $host,
		PeerPort => "$proto($port)",
		Proto => 'tcp',
		SSL_startHandshake => ($proto eq 'wss' ? 1 : 0),
		Blocking => 1
	) or $cbConnectFailed->("Failed to connect to socket: $@");

	main::INFOLOG && $log->is_info && $log->info("Trying to create Protocol::WebSocket::Client handler for $url...");
	$self->{client} = Protocol::WebSocket::Client->new(url => $url);

	# Set up the various methods for the WS Protocol handler
	#  On Write: take the buffer (WebSocket packet) and send it on the socket.
	$self->{client}->on(
		write => sub {
			my $client = shift;
			my ($buf) = @_;

			main::INFOLOG && $log->is_info && $log->info("Sending $buf ...");

			syswrite $self->{tcp_socket}, $buf;
		}
	);

	# On Connect: this is what happens after the handshake succeeds, and we
	#  are "connected" to the service.
	$self->{client}->on(
		connect => sub {
			my $client = shift;
			main::INFOLOG && $log->is_info && $log->info("Successfully Connected to $url...");
			$cbConnected->();
		}
	);

	$self->{client}->on(
		error => sub {
			my $client = shift;
			my ($buf) = @_;

			$log->warn("ERROR ON WEBSOCKET: $buf");
			$self->{tcp_socket}->close;
			exit;
		}
	);

	$self->{client}->on(
		read => sub {
			my $client = shift;
			my ($buf) = @_;
			main::INFOLOG && $log->is_info && $log->info("Message Recieved : $buf");
			$cbRead->($buf);
		}
	);


	main::INFOLOG && $log->is_info && $log->info("connecting to client");
	$self->{client}->connect;

	# read until handshake is complete.
	while (!$self->{client}->{hs}->is_done){
		my $recv_data;

		my $bytes_read = sysread $self->{tcp_socket}, $recv_data, 16384;

		if (!defined $bytes_read) {
			$log->warn("sysread on tcp_socket failed: $!");
			return;
		}elsif ($bytes_read == 0) {
			$log->warn("Connection terminated.");
			return;
		}

		$self->{client}->read($recv_data);
	}

	return;
}


sub wssend {
	my ($self, $buf) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("Sending : " . Dumper($buf));
	$self->{client}->write($buf);

}


sub wsreceive {
	my ($self, $timeout, $cbY, $cbN ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++wsreceive");

	my $s = IO::Select->new();
	$s->add($self->{tcp_socket});
	$! = 0;
	my @ready = $s->can_read($timeout);
	if (@ready) {
		main::DEBUGLOG && $log->is_debug && $log->debug("handles : " . Dumper(@ready));
		my $recv_data;
		my $bytes_read = sysread $ready[0], $recv_data, 16384;
		if (!defined $bytes_read) {
			$log->error("Error reading from socket : $!");
			$cbN->();
		} elsif ($bytes_read == 0) {

			# Remote socket closed
			$log->warn("Connection terminated by remote.");
			$cbN->();
		} else {
			$cbY->();
			main::DEBUGLOG && $log->is_debug && $log->debug("Received data : " . Dumper($recv_data));
			$self->{client}->read($recv_data);

		}

	}

}

sub wsclose {
	my ($self) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++wsclose");
	
	$self->{client}->disconnect;
    $self->{tcp_socket}->close;
	
	main::DEBUGLOG && $log->is_debug && $log->debug("--wsclose");	
	return;
}
1;