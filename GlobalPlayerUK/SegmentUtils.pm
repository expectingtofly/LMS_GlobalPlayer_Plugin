package Plugins::GlobalPlayerUK::SegmentUtils;

# This code is written by bpa in the PlayHLS plugin.  It is his copyright.

use strict;
use bytes;

use URI::Split;
use Data::Dumper;

use Slim::Utils::Errno;
use Slim::Utils::Log;
use URI::Escape;
use Encode;

my $log = logger('plugin.globalplayeruk');


sub getSegmentsuffix {
	
	my $url = shift;
	
	my ($scheme, $auth, $path, $query, $frag) = URI::Split::uri_split($url);
	my $suffix ;
	if (defined $path && $path =~ m%\.([^./]+)$%) {
			$log->debug(" HLS Segment suffix $1 for url $url");
			$suffix = $1;
	} ;
	return $suffix;
}

#####  Check Segment for MPEG2 format


sub checkMPEG2Segment {

# Check segment is mulitple of 188 bytes and has minimum of 3 188 bytes frame - each one starting with 0x47.
	my $segment = shift;
	my $seglen = length($segment);

# MPEG2 segment must at least have 3 packets - PMTY, PAT and data.
	return 0 if ($seglen < 3 * 188);

# First three packets - should have -x47 in first byte.   Some player chekc for this sequeence at offset.  May be necessary in future.
	
	return 0 unless ((substr($segment,  0, 1) eq "\x47") && 
	                 (substr($segment,188, 1) eq "\x47") &&
	                 (substr($segment,376, 1) eq "\x47") )  ;
#	check segment lebgth is an even mulitple of 188  (i.e. remainder after division by 188 should be zero) 

	return 0 if (( $seglen % 188 ) != 0) ;
	return 1;  # look like a MPEG2 sgement
	
}

### Check segment for mPEG-4 format

sub checkMPEG4Segment {
	
	my $segment    = shift;
	my $seglen     = length($segment);
	my $searchlen  = ($seglen < 16384) ? $seglen : 16384;
# Look for a 'moof' atom in the first 16kb of segment.
	return 0 if (index(substr($segment,0,$searchlen), 'moof',0) == -1) ;
	return 1;
} 

##############   Check for ADTS  headers in packed audio segment.

sub checkADTSSegment {
# First get URL suffix - normally .ts , .mp3 or .aac - no standard but an indicator if all else fails

		my $segment = shift;
		my %tagshash;
		my $bytesused = getID3frames(\%tagshash,$segment);
		$log->info("ID3 Bytes skipped $bytesused");
		$log->info(" Tags found".Dumper(\%tagshash)) if ($bytesused) ;
	
# Check for header sync sequence  0xFF 0xFF 0xFz  : where z = ?00? - and then also check frame length and that next frame also has header
# See https://wiki.multimedia.cx/index.php?title=ADTS

		my $offset = $bytesused;

# same as isHeader but we also check that ADTS frame follows last ADTS frame
# or end of data is reached
		if (isADTSHeader($segment, $offset)) {
#		get ADTS header Length to check next frame also has header

			my $streamdetails =  getADTSdetails($segment, $offset);

			my $headerLength = getADTSHeaderLength($segment, $offset);
			my $frameLength  = $headerLength;

			if ($offset + 5 < length($segment)) {
				$frameLength = getADTSFullFrameLength($segment, $offset);
			} ;

			my $newOffset = $offset + $frameLength;
			return 1 if ( ($newOffset == length($segment) || 
			            ( ($newOffset + 1) < length($segment) && isADTSHeader($segment, $newOffset))) ) ;
		}
  return 0;

}

sub isADTSHeader {
	my ($data, $offset) = @_;
	return ( (ord(substr($data,$offset,1)) == 0xff) && ((ord(substr($data,$offset+1,1)) & 0xf6) == 0xf0)) ; 
}

sub getADTSdetails {
	my ($data, $offset) = @_;
	my $audioobjtype = (ord(substr($data,$offset+2,1)) >> 6) & 0x03;
	my $samplefreq   = (ord(substr($data,$offset+2,1)) >> 2) & 0x0F;
	my $channels     = ((ord(substr($data,$offset+2,1)) & 0x01) << 2 ) | ((ord(substr($data,$offset+3,1)) >> 6) & 0x03);
	
#	$log->info(sprintf(" ADTS Frame %08b %08b %08b %08b ", 
#					ord(substr($data,$offset+0,1)),ord(substr($data,$offset+1,1)),
#					ord(substr($data,$offset+2,1)),ord(substr($data,$offset+3,1))
#					));
	$log->info(" Object-type $audioobjtype Sample rate $samplefreq  Channels $channels ");
	
	return  { 'Audio_type' => $audioobjtype, 'Sample_rate'=> $samplefreq , 'Channel_config' => $channels};
}

sub getADTSHeaderLength {
	my ($data, $offset) = @_;
	return  (ord(substr($data,$offset+1,1)) & 0x01) ? 7 : 9 ;
}

sub getADTSFullFrameLength {
	my ($data, $offset) = @_;
	return ( ((ord(substr($data,$offset+3,1)) & 0x03) << 11) |
              (ord(substr($data,$offset+4,1))         << 3 ) |
             ((ord(substr($data,$offset+5,1)) & 0xE0) >> 5 ) );
}

##############   Chech MP3 headers

sub checkMP3Segment {
	my $segment = shift;
	my %tagshash;
	my $bytesused = getID3frames(\%tagshash,$segment);
	$log->info("ID3 Bytes skipped $bytesused");
	$log->info(" Tags found".Dumper(\%tagshash)) if ($bytesused) ;
	
# Check for header sync sequence  0xFF 0xFF 0xFz  : where z = ?00? - and then also check frame length and that next frame also has header
# See http://www.mp3-tech.org/programmer/frame_header.html

	my $offset = $bytesused;

# Check for sync sequence  0xFF 0xFF 0xFz  : where z = ?11?
	
    my $framelength = ((length($segment)- 1) < ($offset + 100)) ? (length($segment) - 1) : ($offset + 100) ;
      
    for (my $i = $offset; $i < length($segment); $i++) {
		if (isMP3Header($segment, $offset)) {
			$log->debug('MPEG Audio sync word found !');
			return 1;
        }
	}
 return 0;
}

sub isMP3HeaderPattern {
	
		my ($segment, $offset) = @_;
		
		return (( ord(substr($segment,$offset,  1))         == 0xFF) && 
		        ((ord(substr($segment,$offset+1,1)) & 0xE0) == 0xE0) && 
		        ((ord(substr($segment,$offset+1,1)) & 0x06) != 0x00) );
}

sub isMP3Header{
		my ($data, $offset) = @_;
#	Look for MPEG header | 1111 1111 | 111X XYZX | where X can be either 0 or 1 and Y or Z should be 1
#	Layer bits (position 14 and 15) in header should be always different from 0 (Layer I or Layer II or Layer III)
#	More info http://www.mp3-tech.org/programmer/frame_header.html

    return 1 if ((($offset + 1) < length($data)) && isMP3HeaderPattern($data, $offset));

    return 0;
}


#
#  MP3 Header - MPEG Audio Layer I/II/III frame header
#  32 bits  - AAAAAAAA AAABBCCD EEEEFFGH IIJJKLMM
#
#   A  Frame Sync
#   B  MPEG Audio Version ID  (MPEG V1, V2 or V2.5) 
#   C  Layer description  (Layer I, II, III)
#   D  CRC protection
#   E  Bit rate index
#   F  Samplign rate Freq
#   G  Pafdding
#   H  Private
#   I  Channel mode
#   J  Mode extension
#   K  Copyright
#   L  Original 
#   M  Emphasis
#

#   V1,L1  V1,L2  V1,L3  V2.L1  V2, L2 & L3
my @mp3_bitrates = (
	[  0,   0,   0,   0,   0],  # EEEE = 0000
	[ 32,  32,  32,  32,   8],
	[ 64,  48,  40,  48,  16],
	[ 96,  56,  48,  56,  24],
	[128,  64,  56,  64,  32],
	[160,  80,  64,  80,  40],
	[192,  96,  80,  96,  48],
	[224, 112,  96, 112,  56],
	[256, 128, 112, 128,  64],
	[288, 160, 128, 144,  80],
	[320, 192, 160, 160,  96],
	[352, 224, 192, 176, 122],
	[384, 256, 224, 192, 128],
	[416, 320, 256, 224, 144],
	[448, 384, 320, 256, 160],
	[ -1,  -1,  -1,  -1,  -1] ); # EEEE = 1111

#       MPEG V2.5, res, MPEG V2, MPEG V1 
my @mp3_samplefreq = (
     	[11205, -1, 22050, 44100],     # FF = 00
     	[12000, -1, 24000, 48000],     # FF = 01
     	[ 8000, -1, 16000, 32000],     # FF = 10
     	[   -1, -1,    -1,    -1]);    # FF = 11

sub getMP3details {

	my ($data, $offset) = @_;
	my $mpeg_layer = -1;
	
	my $BB     = (ord(substr($data,$offset+1,1)) >> 3) & 0x03;
	my $CC     = (ord(substr($data,$offset+1,1)) >> 1) & 0x03;
#	my $D      = (ord(substr($data,$offset+1,1)) >> 1) & 0x01;

	my $EEEE   = (ord(substr($data,$offset+2,1)) >> 4) & 0x0F;
	my $FF     = (ord(substr($data,$offset+2,1)) >> 2) & 0x03;
#	my $G      = (ord(substr($data,$offset+2,1)) >> 1) & 0x01;
#	my $H      =  ord(substr($data,$offset+2,1))       & 0x01;

	my $II     = (ord(substr($data,$offset+3,1)) >> 6) & 0x03;
#	my $JJ     = (ord(substr($data,$offset+3,1)) >> 4) & 0x03;
#	my $K      = (ord(substr($data,$offset+3,1)) >> 3) & 0x01;
#	my $L      = (ord(substr($data,$offset+3,1)) >> 2) & 0x01;
#	my $MM     =  ord(substr($data,$offset+3,1))       & 0x03;

	if ($BB eq 3) {                      # MPEG V1
		$mpeg_layer = 0 if ( $CC eq 3 );    #  V1 L1
		$mpeg_layer = 1 if ( $CC eq 2 );    #  V1 L2
		$mpeg_layer = 2 if ( $CC eq 1 );    #  V1 L3
	} elsif ( $BB eq 2 || $BB eq 0) {    # MPEG V2 & V2.5
		$mpeg_layer = 3 if ( $CC eq 3 );    #   L1
		$mpeg_layer = 4 if ( $CC eq 2 || $CC eq 1);  #   L2 & L3
	};

	my $bitrate    = $mp3_bitrates[$EEEE][$mpeg_layer];
	my $samplefreq = $mp3_samplefreq[$FF][$BB];
	
	$bitrate    = undef if ($bitrate    eq -1);
	$samplefreq = undef if ($samplefreq eq -1);
	
	my $channels   = ($II eq 3) ? 1 : 2;  # Mono 1 channel if 11  otherwise if Stereo, Joint Stereo, Dual Channel - 2 channels  
	
	$log->info("Version $BB  Layer $CC bitrate $bitrate Sample freq $samplefreq  Channels $channels ");
	
	return  { 'Version' => $BB, 'Layer' => $CC, 'Bitrate' => $bitrate *1000 , 'Sample_freq'=> $samplefreq , 'Channel_config' => $channels};
}


##################### ID3  Tag Handling ####################

sub startID3frame {
	
	my $id3frames = shift;
	my $rawdata      = shift;

	
	my $datalen = length($rawdata);
	
	$log->debug(sprintf("decode ID3 rawdata %0*v2X\n", " ", substr($rawdata,0,128))); 
	
	if ( 10 > $datalen) {
		$log->error( "Not enough bytes for ID3 header ");
		return;
	}; 
	
	my ($type, $major_version, $revision_number, $flags, $id3_size1, $id3_size2, $id3_size3, $id3_size4 ) = unpack
		"A3".       # 24 bits (3 Bytes, ASCII text) "ID3".  (3 Bytes Header_ID).
		"C".        #  8 bits (1 Byte,  hex string) Version (1 Byte  Major_Version).
		"C".        #  8 bits (1 Byte,  hex string) Version (1 Byte  Revision number).
		"C".        #  8 bits (1 Byte,  hex string) Flags   (1 Byte  Flags).
		"CCCC",     #  8 bits (4 Bytes, Integer),   Size    (4 Bytes Size).
		substr($rawdata,0,10) ;
			
	if ($type ne 'ID3') {   #            Not ID3 - return null - failure or finished ID3 headers
	   return; 
	} ;	
		
	if (($major_version == 0xFF) || ( $revision_number == 0xFF)) {
	  $log->error(  "Invalid Version number ( $major_version ) or revision or version number ($revision_number )");
	   return; 
	} ;
		
	if ( ($id3_size1 > 0x80) || ($id3_size2 > 0x80) || ($id3_size3 > 0x80) || ($id3_size4 > 0x80) ) {
	   $log->error(  "Invalid size byte: $id3_size1 $id3_size2 $id3_size3 $id3_size4");
	   return; 
	} ;
		
	my $id3frame = {
					'type'               =>  $type,
					'version'            =>  $major_version,
					'revision'           =>  $revision_number ,
					'unsynchronisation'  =>  $flags & 0x80 , 
					'extended'           =>  $flags & 0x40 , 
					'experimental'       =>  $flags & 0x20 ,
					'size'               => ((($id3_size1 & 0x7f) << 21) | (($id3_size2 & 0x7f) << 14) | (($id3_size3 & 0x7f) << 7) | ($id3_size4 & 0x7f)),
	} ;
		
	if ($id3frame->{'extended'}) {
		$log->error(  "Warning Extended ID3 header - not processes ");
	};
		
	$rawdata = substr($rawdata,10);

	return $id3frame;	
} ;

sub getID3frames {
	
	my $tagshash   = shift;
	my $rawdata    = shift;
	my $rawdatalen = length($rawdata);
	my $id3frames;
	
	while (my $id3frame = startID3frame($id3frames,$rawdata) ) {
		my $framedata = substr($rawdata,10, $id3frame->{'size'});
		my $framedatalen = length($framedata) ;
		
		my @tags;
		
		while ( $framedatalen > 0 ) {
			my ($frameid, $frame_size1, $frame_size2, $frame_size3, $frame_size4, $frameflags) = unpack "A4CCCCn", $framedata;
			my $frame_size = ((($frame_size1 & 0x7f) << 21) | (($frame_size2 & 0x7f) << 14) | (($frame_size3 & 0x7f) << 7) | ($frame_size4 & 0x7f)) ;
			my $tagdata = substr($framedata,10,$frame_size);
			
			my %frame     = ('type' => $frameid, 'size' => $frame_size, 'flags' => $frameflags ) ;
			decodeFrame(\%frame, $tagdata);
			push @tags, \%frame ;
			$framedata = substr($framedata,($frame{'size'} + 10));
			$framedatalen = length($framedata) ;
		} ;

		foreach my $tag (@tags) {
		  $tagshash->{$tag->{'type'}} =  $tag; 	
		} ;
		
		$id3frame->{'tags'} = [@tags];
		@tags = undef;
		push @{$id3frames}, $id3frame;
		$rawdata = substr($rawdata,$id3frame->{'size'} + 10);
	};
	
  # Return bytes read from segment for ID3 tags
  return ( $rawdatalen - length($rawdata) );
}
	
sub decodeFrame {
	my $frame   = shift;
	my $rawdata = shift;
	
#	$log->error("                                   -------> Frame type \"".$frame->{'type'}. "\"  Decode frame length of rawdata ".length($rawdata));
	
	if ($frame->{'type'} eq 'PRIV' ) {
		 return decodePrivFrame( $frame, $rawdata ) ;
	} elsif (substr($frame->{'type'} ,0,1) eq 'T' ) {
		 return decodeTextFrame( $frame, $rawdata ) ;
	} elsif (substr($frame->{'type'} ,0,1) eq 'W' ) {
		 return decodeURLFrame( $frame, $rawdata ) ;
	} ;
   return ;	
}

sub decodePrivFrame {

#    Format: <text string>\0<binary data>
	my $frame   = shift;
	my $rawdata = shift;
    if (length($rawdata) < 2) {
	  $log->error(  "Error length too short " );
      return ;
    } ;

	my $ownerlength = index( $rawdata,"\x00");
	$frame->{'priv_owner'} =  substr( $rawdata, 0, $ownerlength);
	my $privdatalen = length($rawdata) - $ownerlength ;

# Private key com.apple.streaming.transportStreamTimestamp should have an 8 octet time stamp - only 33 bits are used
	$log->error( "Error  Unexpected private key: " . $frame->{'priv_owner'} ) if ($frame->{'priv_owner'} ne 'com.apple.streaming.transportStreamTimestamp') ;
	$log->error( "Error wrong private key length ($ownerlength)  " .(length(substr( $rawdata, $ownerlength+1)))) if ((length(substr( $rawdata, $ownerlength+1))) != 8);
	
	 if ((length(substr( $rawdata, $ownerlength+1))) != 8) {
		my $dumplength = (length($rawdata) > 64 ) ?  64 : length($rawdata); 
		$log->error(sprintf("decode priv owner rawdata %0*v2X\n", " ", substr($rawdata,0,$dumplength))); 
		my $privstring = substr($rawdata,0,$ownerlength);
		$log->error("decode priv owner string \"$privstring\""); 
	}


	my ($privkey_hi,$privkey_lo ) = unpack "NN",substr( $rawdata, $ownerlength+1);
	$frame->{'priv_private'} = ($privkey_hi << 32) | $privkey_lo;
    return ;
}
# Text encoding 

# 0 = latin1 (effectively: unknown)
# 1 = UTF-16 with BOM   (we always write UTF-16le to cowtow to M$'s bugs)
# 2 = UTF-16be, no BOM
# 3 = UTF-8

my @dec_types = ( 'iso-8859-1', 'UTF-16',  'UTF-16BE',  'utf8' );


sub decodeTextFrame {
#    Format: <text string>\0<binary data>

	my $frame   = shift;
	my $rawdata = shift;
    if (length($rawdata) < 2) {
      return ;
    } ;
    
	if ($frame->{'type'} eq 'TXXX' ) {

#   Format:
#      [0]   = {Text Encoding}
#      [1-?] = {Description}\0{Value}

		$frame->{'TXXX_encoding'} = ord(substr($rawdata,0,1));
		$rawdata = substr($rawdata,1);

		my $nullpos = index($rawdata,'\0');
		$frame->{'TXXX_description'} = substr($rawdata,0,$nullpos);
        $frame->{'TXXX_description'} = decode_encoded($frame->{'TXXX_encoding'},$frame->{'TXXX_description'});

		$frame->{'TXXX_value'} = substr($rawdata,$nullpos+1);

   } else {
#      Format:
#      [0]   = {Text Encoding}
#      [1-?] = {Value}
		$frame->{'TEXT_encoding'}    = ord(substr($rawdata,0,1));
		$frame->{'TEXT_description'} = substr($rawdata,1,$frame->{'size'}-1);
        $frame->{'TEXT_description'} = decode_encoded($frame->{'TEXT_encoding'},$frame->{'TEXT_description'});
#        $log->error("Type:" . $frame->{'type'}. " Encoding:". $frame->{'TEXT_encoding'}. "(". $dec_types[$frame->{'TEXT_encoding'}] .")\n Text:". $frame->{'TEXT_description'} . "\n Decoded:". decode_encoded($frame->{'TEXT_encoding'},$frame->{'TEXT_description'}));
        
    } ;
	return;
}

sub decodeURLFrame {
	my $frame   = shift;
	my $rawdata = shift;
    
    if (length($rawdata) < 2) {
      return ;
    } ;
    
	if ($frame->{'type'} eq 'WXXX' ) {

#   Format:
#      [0]   = {Text Encoding}
#      [1-?] = {Description}\0{Value}

		$frame->{'WXXX_encoding'} = substr($rawdata,0,1);
		$rawdata = substr($rawdata,1);

		my $nullpos = index($rawdata,'\0');
		$frame->{'WXXX_description'} = substr($rawdata,0,$nullpos);
        $frame->{'WXXX_description'} = decode_encoded($frame->{'WXXX_encoding'},$frame->{'WXXX_description'});
		
        $frame->{'WXXX_value'} = substr($rawdata,$nullpos+1);

   } else {
#      Format:
#      [0]   = {Text Encoding}
#      [1-?] = {Value}
		$frame->{'W_encoding'}  = ord(substr($rawdata,0,1));
		$frame->{'W_URL'} = substr($rawdata,1,$frame->{'size'}-1);
		
    } ;
	return;	
}

use utf8;
sub decode_encoded {
    my $encoding = shift;
    my $str      = shift;
    
    
    if ( $encoding > 3 ) {
       $log->error("Encoding type '$encoding' not supported using latin1 ");
       $encoding = 0;
    }
    my $decoded_str = Encode::decode($dec_types[$encoding], $str);
    $log->debug("Encoding $encoding Decoded:$decoded_str"); 

    return $decoded_str;
}

