# ext2salvage

Salvage files from corrupted ext2 file system

`usage`

perl ./recovery.pl -d disk_path -t file_type -s block_size -p recover_path 

`parameters`

-h: help 

-d: disk_path, the disk's path, of which formated by ext2 where file to be salvaged

-t: file types that need to be recovered, supports multiple salvage multiple types at a time, seperated by comma, ex: '-d pdf,mp4,txt'

-s: block_size_in_byte, the block size of file system 

-p: recover_path, the path where recovered file to put

`trial steps`

- prepare a LUN (virtual disk)

- format the LUN with ext2 file-system

- mount the formated file-system

- create/copy some test file into the file-system

- remove the test files

- umount the file-system

- corrupt the superblock and other metatdata of the filesystem by 'dd' command

- use salvage.pl to salvage the test files

