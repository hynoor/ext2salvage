#####################################################
# salvage.pl is a tool used to refund the files from
# etiher corrupted filesystem or accidental deletion
#
# Author: Hang Deng | hang.deng2@emc.com | July, 2015
#####################################################

use warnings;
use strict;
use Getopt::Std;
use Fcntl qw(/^O_/ /^SEEK_/);

# This hash table is expandalbe for supporting more file types
# Usually using first 4 bytes for identification
my %fileTypeMap = (
    'ffd8ffe0'                 => "jpg",
    '89504e47'                 => "png",
    '25504446'                 => "pdf",
    '4d5a9000'                 => "exe",
    '1f8b08'                   => "tar.gz",
    '00000018667479706d703432' => "mp4",
    '49443303'                 => "mp3",
    '2e524d46'                 => "rmvb",
    '23696e63'                 => "txt",
);

my $initTimeStamp     = time();
my $fileNamePrefix    = "recovered_file_";
my $blockSizeInByte   = 4096;
my $recoverPath       = "./";
my @expectCharaCodes  = ();
my %opts              = ();
my $diskPath          = undef;
my $fileType          = undef;
my $buf               = undef;

sub usage {
    print ("\nUSAGE:");
    print ("\nUsage: perl ./recovery.pl -d disk_path -t file_type -s block_size -p recover_path");
    print ("\n-h: help");
    print ("\n-d: disk_path, the disk's path which need to be recovered");
    print ("\n-t: file types that need to be recovered");
    print ("\n-s: block_size_in_byte, the block size of file system");
    print ("\n-p: recover_path, the path where recovered file to put\n");
    exit(0);
} # end sub usage

getopts('hd:t:s:p:', \%opts);
if ( exists $opts{h} ) { usage(); }

if   ( !exists $opts{d} ) {
     print ("-d disk_path is required,  but missing\n");
     usage();
}
else{
     $diskPath = $opts{d};
}

if(!$opts{t}){
    print ("Error: target recover file type required, but it is missing\n");
    usage();
}
else{
    $fileType = $opts{t};
    my @fileTypes = split /,/, $fileType; 
    foreach my $ft (@fileTypes) {
        my @fsCharaCodes = keys %fileTypeMap;
        foreach my $charaCode (@fsCharaCodes) {
            if ($fileTypeMap{$charaCode} eq $ft) {
                push @expectCharaCodes, $charaCode;
            }
        }
    }
}

if($opts{s}){
    $blockSizeInByte = $opts{s};
}

if($opts{p}){
    $recoverPath = $opts{p};
}
msg ("___________________________________________");
msg ("___________ SALVAGE SUMMARY _______________");
msg ("                                           ");
msg ("    File types    | $fileType              ");
msg ("    Block Size    | $blockSizeInByte" ."B  ");
msg ("    Source Disk   | $diskPath              ");
msg ("    Refund Path   | $recoverPath           ");
msg ("___________________________________________");
msg ("Start to scan disk $diskPath ... \n");

if (scalar(@expectCharaCodes) == 0) {
    msg ("[ERROR] Didn't find expected chara code, please confirm the file type");
    exit();
}

my %startBlockNumHash = %{
    scanDisk(
        $diskPath, 
        \@expectCharaCodes, 
        $blockSizeInByte,
    )
};

# find out the exact inode blocks, to signically save the time
my $diskGroupRef      = dumpe2fs($diskPath);
my $inodeBlockRef     = getInodeBlockIndex($diskGroupRef);
my @startBlockNumbers = keys %startBlockNumHash;

foreach my $startNum (@startBlockNumbers) {
    msg ();
    msg ("----------- Recovering start at block #$startNum -----------");
    my $fileData = undef;
    if ( (my $startBlockIndex = scanInodeForBlockIndex($diskPath, $startNum, $blockSizeInByte, $inodeBlockRef)) != -1 ) {
        msg ("Scanning for inode ...");
        $fileData = recoverFileByInode($diskPath, $startBlockIndex, $blockSizeInByte);
        
    }
    else {
        msg ("Scanning for inode failed, now switch to force recover mode ...");
        $fileData = forceRecoverFile($startNum, $blockSizeInByte);
    }

    constructSingleFile(
        $fileData, 
        $recoverPath . $fileNamePrefix . $startNum . "." . $fileTypeMap{$startBlockNumHash{$startNum}},
    );
    msg ("------------------ #$startNum Recovery DONE ------------------");
}

msg ("Totally " . scalar(@startBlockNumbers) . " file(s) have refunded!");

sub scanDisk
{
    my $diskPath     = shift @_;
    my @fileTypes    = @{shift @_};
    my $blockSize    = shift @_;

    if(!sysopen(DISK, $diskPath, O_RDONLY)){
        my $sysErrorMsg = $!;
        msg ("[ERROR] $sysErrorMsg");
        exit();
    }

    binmode DISK;
    my $count          = 0;
    my $idx            = 0;
    my %targetIndexes  = ();

    while (sysread(DISK, $buf, 4096)) {
        my $hexBuf = unpack("H*", $buf);
        # seek for expected signature code in given block size 
        # and the position must be at the begining of a data block
        foreach my $fileType (@fileTypes) {
            if (index($hexBuf, $fileType) == 0) {
                msg ("Found expected signature code at the entry of data block #$idx");
                $targetIndexes{$idx} = $fileType;
            }
        }
        if (($idx%5000) == 0) {
            msg ("$idx blocks scanned ...");
        }
        $idx++;
        # limit the scan area to save time
        if ($idx == 100000) {
            last;
        }
    }
    if(scalar(keys %targetIndexes) == 0) {
        msg("[FAILED] Failed to find any signature code, file recovery failed !!!");
        close DISK;
        exit(0);
    }
    msg("Found " . scalar(keys %targetIndexes) . " signature code candidate(s)");
    close DISK;
    return \%targetIndexes;

}

sub forceRecoverFile
{
    my $dataBlockStart        = shift @_;
    my $blockSizeInByte       = shift @_;
    my $buf                   = undef; 
    my $fileData              = undef;
    my $directDataCount       = 0;
    my $recoveredDataBlkNum   = 0;
    my $continue              = 1;
    my @indirectIndexes       = ();
    my @doubleIndirectIndexes = ();
    if(!sysopen(DISK, $diskPath, O_RDONLY)){
        my $sysErrorMsg = $!;
        msg ("$sysErrorMsg");
    }
    binmode DISK;

    # findng the first 12 direct data blocks ...
    for my $i (0..11) {
        if (seek (DISK, (($dataBlockStart + $i) * $blockSizeInByte), 0)) {
            sysread(DISK, $buf, $blockSizeInByte);
        }
        if($buf) {
            $fileData .= $buf;
            $directDataCount++;
            $recoveredDataBlkNum++;
        }
    }
    # analyse the 13th address stores the indirect blocks
    if (seek (DISK, (($dataBlockStart + 12) * $blockSizeInByte), 0)) {
        sysread(DISK, $buf, $blockSizeInByte);
    }
    @indirectIndexes = @{&formatBlockIndex($buf)};
    msg ("12 direct data blocks were found, total number of data blocks: $recoveredDataBlkNum");

    # finding indirect data blocks ...
    my $lastIndirectBlockIndex = 0;
    my $numIndirectIndex       = 0;
    my @nonZeroIndexes         = ();
    for my $i (0..1023) {
        if ($indirectIndexes[$i] != 0) {
            $numIndirectIndex++;
        }
    }

    msg ("Number of indirect index: $numIndirectIndex");
    if ($numIndirectIndex < 1024) {
        msg ("There isn't double indirect blocks exist");
        $continue = 0;
    }

    for my $pos (0..($numIndirectIndex-1)) {
        seek (DISK, ($indirectIndexes[$pos] * $blockSizeInByte), 0);
        sysread (DISK, $buf, $blockSizeInByte);
        if($buf) {
            $fileData .= $buf;
            $recoveredDataBlkNum++;
        }
        msg ("Indirect index[$pos]: $indirectIndexes[$pos]");
        $lastIndirectBlockIndex = $indirectIndexes[$pos];
    }
    msg ("$numIndirectIndex indirect data blocks were found, total number of data blocks: $recoveredDataBlkNum\n");
    msg ("The last indirect block index is: $lastIndirectBlockIndex");

    if ($continue) {
        # find the double indirect index 
        seek (DISK, (($lastIndirectBlockIndex + 1) * $blockSizeInByte), 0);
        sysread(DISK, $buf, $blockSizeInByte);
        @doubleIndirectIndexes = @{&formatBlockIndex($buf)};
        my $count                  = 0; 
        my $numDoubleIndirectIndex = 0;
        for my $i (0..1023) {
            if ($doubleIndirectIndexes[$i] != 0) {
                $numDoubleIndirectIndex++;
                msg ("double indirect index[$i]: $doubleIndirectIndexes[$i]");
               
            }
        }
        msg ("Number of double indirect index: $numDoubleIndirectIndex\n");
        for my $i (0..($numDoubleIndirectIndex-1)) {
            seek (DISK, ($doubleIndirectIndexes[$i] * $blockSizeInByte), 0);
            sysread (DISK, $buf, $blockSizeInByte);
            my @dataBlockIndexes = @{&formatBlockIndex($buf)};
            my $numDataBlock = 0; 
            for my $j (0..1023) {
                if ($dataBlockIndexes[$j] != 0) {
                    $numDataBlock++;
                }
            }
            for my $pos (0..($numDataBlock-1)) {
                seek (DISK, ($dataBlockIndexes[$pos] * $blockSizeInByte), 0);
                sysread(DISK, $buf, $blockSizeInByte);
                if($buf) {
                    $fileData .= $buf;
                    $recoveredDataBlkNum++;
                    $count++;
                }
            }
            msg("Progress of reading double indirect data blocks:  
                 count: $count | numDoubleIndirectIndex: $numDoubleIndirectIndex | numDataBlock: $numDataBlock");
        }
        msg ($count . " double indirect data blocks were found, total number of data blocks: $recoveredDataBlkNum");
    }

    close DISK;
    return $fileData;
    
}


sub constructSingleFile
{
    my $fileContent = shift @_;
    my $filePath    = shift @_;

    open(FH, ">", $filePath) || die;
    syswrite (FH, $fileContent);
    close FH;

    msg ("[SUCCEED] File $filePath was successfully recovered");
 
}

sub formatBlockIndex 
{
    my $content = unpack("H*", shift @_); 
    my @blockIndexes = ();
    for(my $idx=0; $idx<=1023; $idx++) {
        # constructing the block indexes of 1st level indirect data blocks
        my $blockIdx = substr($content, 8*$idx, 8);
        # divide string to 4 x 2 bytes parts
        my $aPart = substr($blockIdx, 0, 2);
        my $bPart = substr($blockIdx, 2, 2);
        my $cPart = substr($blockIdx, 4, 2);
        my $dPart = substr($blockIdx, 6, 2);
        # reverse all of parts then add HEX tag
        # ps: this handling to for Intel and DEC chips (little endian), but Motorola doesn't
        my $hexStr   = "0x" . $dPart . $cPart . $bPart . $aPart;
        push @blockIndexes, hex($hexStr); 
    }
    
    return \@blockIndexes;

}

sub formatHex
{
    my $content  = unpack("H*", shift @_);
    # divide string to 4 x 2 bytes parts
    my $aPart    = substr($content, 0, 2);
    my $bPart    = substr($content, 2, 2);
    my $cPart    = substr($content, 4, 2);
    my $dPart    = substr($content, 6, 2);
    # reverse a part and b part then add HEX tag
    my $hexStr   = "0x" . $dPart . $cPart . $bPart . $aPart;
    
    return hex($hexStr);
}

=begin
sub formatBlockIndex 
{
    my $content = unpack("H*", shift @_); 
    my @blockIndexes = ();
    for(my $idx=0; $idx<=1023; $idx++) {
        # constructing the block indexes of 1st level indirect data blocks
        my $blockIdx = substr($content, 8*$idx, 8);
        my $formatedContent = formatHex($blockIdx);
        push @blockIndexes, $formatedContent; 
    }
    return \@blockIndexes;

}
=cut
sub dumpe2fs
{
    my $disk = shift @_;

    my $cmd = "sudo dumpe2fs $disk";
    my $res = `$cmd`;

    my $groupId = 0;
    my @diskGroups = ();
    # get gropu info 
    while ($res =~ /Group (\d+): \(Blocks (\d+)-(\d+)\)/g) {
        my %groupInfo = ();
        $groupInfo{id}          = $1;
        $groupInfo{start_block} = $2;
        $groupInfo{end_block}   = $3;
        push @diskGroups, \%groupInfo;
    } 
    
    # inode table locaitons 
    while ($res =~ /Inode table at (\d+)-(\d+)/g) {
        ${$diskGroups[$groupId]}{'start_inode'} = $1;
        ${$diskGroups[$groupId]}{'end_inode'}   = $2; 
        ${$diskGroups[$groupId]}{'num_inode'}   = $2 - $1 + 1; 
        $groupId++;  
    }
   
    return \@diskGroups;
}

sub getInodeBlockIndex
{ 
    my @diskGroups = @{shift @_};

    my @inodeBlockIndexes;
    foreach my $dg (@diskGroups) {
        my $startIdx = ${$dg}{'start_inode'};
        my $endIdx   = ${$dg}{'end_inode'};

        for my $i ($startIdx..$endIdx) {
            push @inodeBlockIndexes, $i;            
        }
    }
    
    return \@inodeBlockIndexes;
}

sub scanInodeForBlockIndex
{
    my $diskPath      = shift @_;
    my $startBlock    = shift @_;
    my $blockSize     = shift @_;
    my $inodeIndexRef = shift @_;

    if(!sysopen(DISK, $diskPath, O_RDONLY)){
        my $sysErrorMsg = $!;
        print ("$sysErrorMsg\n");
    }

    binmode DISK;
    my @inodeTableIndexes = @{$inodeIndexRef};
    my $num4Bytes         = $blockSize / 4;
    my $count             = 0;
    my $idx               = 0;
    my %target            = ();
    my $buf               = undef;
    foreach my $idx (@inodeTableIndexes) { 
        for my $offset (0..($num4Bytes-1)) {
            seek (DISK, ($idx * $blockSize) + ($offset * 4), 0);
            sysread(DISK, $buf, 4);
            my $formatHex = formatHex($buf);
            if ($formatHex eq $startBlock) {
                my $loc = $inodeTableIndexes[0] * $blockSize + $count * 4;
                msg ("Found location of first direct index at $loc ");
                return $loc; 
            }
            $count++;
            if (($count%(1024*100)) == 0) {
                msg ("$count * 4 bytes scanned...");
            }
        }
    }

    close DISK;
    return -1;
}

sub recoverFileByInode
{

    my $diskPath         = shift @_;
    my $firstDirectIndex = shift @_;
    my $blockSize        = shift @_;

    my $buf                        = undef;
    my @directIndexes              = ();
    my @indirectBlockIndexes       = ();
    my @doubleIndirectBlockIndexes = ();
    my $indirectIndex              = 0;
    my $doubleIndirectIndex        = 0;
    my $tripleIndirectIndex        = 0;
    my @noneZeroIndexes            = ();

    if(!sysopen(DISK, $diskPath, O_RDONLY)){
        my $sysErrorMsg = $!;
        msg ("$sysErrorMsg");
    }

    # seek direct indexes
    for my $i (0..14) {
        my $dataIndex = undef;
        if (seek (DISK, $firstDirectIndex+($i*4), 0)){
            sysread(DISK, $buf, 4);
            $dataIndex = formatHex($buf); 
            if (($dataIndex != 0) && ($i < 12)) {
                push @directIndexes, $dataIndex;
            }
        }
        # indirect index
        if ($i == 12) {
            $indirectIndex = $dataIndex;
        }
        # double indirect index
        if ($i == 13) {
            $doubleIndirectIndex = $dataIndex;
        }
        # triple indirect index
        if ($i == 14) {
            $tripleIndirectIndex = $dataIndex;
        }
    }
    # read direct data blocks
    my $data = undef;
    foreach my $index (@directIndexes) {
        if (seek (DISK, ($index*$blockSize), 0)){
            sysread(DISK, $buf, $blockSize);
            $data .= $buf; 
        } 
    }
    msg ("Direct data blocks have been found!"); 

    # leave?
    if ($indirectIndex == 0) {
        msg ("no indirect data blocks found"); 
        close DISK;
        return $data;
    } 

    # seek indirect indexes
    if (seek (DISK, ($indirectIndex * $blockSize), 0)) {
        sysread(DISK, $buf, $blockSize);
        @indirectBlockIndexes = @{formatBlockIndex($buf)};
    }
    
    @noneZeroIndexes = ();
    foreach my $idx (@indirectBlockIndexes) {
        if ($idx != 0) {
            push @noneZeroIndexes, $idx;
        } 
    }
    # read indirect data blocks
    foreach my $idx (@noneZeroIndexes) {
        seek (DISK, ($idx * $blockSize), 0);
        sysread(DISK, $buf, $blockSize);
        $data .= $buf;
    }
    msg ("Indirect data blocks have been found!"); 

    # leave?
    if ($doubleIndirectIndex == 0) {
        msg ("no double indirect data blocks found"); 
        close DISK;
        return $data; 
    }
    
    # seek double indirect indexes
    if (seek (DISK, ($doubleIndirectIndex * $blockSize), 0)) {
        sysread(DISK, $buf, $blockSize);
        @doubleIndirectBlockIndexes = @{formatBlockIndex($buf)};
    }    

    @noneZeroIndexes = ();
    foreach my $idx (@doubleIndirectBlockIndexes) {
        if ($idx != 0) {
            push @noneZeroIndexes, $idx;
        } 
    }
    my $count                    = 1; 
    my @dataBlockIndexes         = (); 
    my @noneZeroDataBlockIndexes = (); 
    my $total = int(scalar(@noneZeroIndexes)/4/32);
    foreach my $idx (@noneZeroIndexes) {
        my @noneZeroDataBlockIndexes = ();
        seek (DISK, ($idx * $blockSize), 0);
        sysread(DISK, $buf, $blockSize);
        @dataBlockIndexes = @{formatBlockIndex($buf)};
        foreach my $index (@dataBlockIndexes) {
            if ($index != 0) {
                push @noneZeroDataBlockIndexes, $index;
            }
        }
        foreach my $bi (@noneZeroDataBlockIndexes) {
            seek (DISK, ($bi * $blockSize), 0);
            sysread(DISK, $buf, $blockSize);
            $data .= $buf;
        }
        $count++;
        if ($count%32 == 0) {
            my $progress = $count/32;
            msg ("Progress of finding double indirect data blocks: $progress/$total"); 
        }
    }
    msg ("Double indirect data blocks have been found!"); 

    # leave?  
    if ($tripleIndirectIndex == 0) {
        msg ("no triple indirect data blocks found"); 
        close DISK;
        return $data; 
    }
}

sub msg  
{
    my $msg     = shift @_;
    if (!defined $msg) {
        $msg = " ";
    }
    my $TIMESTAMP = "";
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, %yday, $isdst);
    ($sec, $min, $hour, $mday, $mon, $year, $wday, %yday, $isdst) = localtime(time());
     
    $year =~ /\d(\d\d)/; 
    $year = $1;

    if ($min < 10) {
        $min = ('0' . $min);
    }

    if ($sec < 10) {
        $sec = ('0' . $sec);
    }
    
    $TIMESTAMP = "$mon\_$mday\_$year $hour:$min:$sec"; chomp $TIMESTAMP;
    print "$TIMESTAMP: $msg\n"; 
    if(!open(LOG, ">>", "r_log_$initTimeStamp")){
        my $sysErrorMsg = $!;
        print "$sysErrorMsg \n";
    }
    print LOG "$TIMESTAMP: $msg\n";
    close LOG;
}

