# ext2salvage

Salvage files from corrupted ext2 file system


### usage

_perl ./recovery.pl -d disk-path -t file-type -s block-size -p recover-path_


### parameters

`-h:` help 

`-d:` disk_path, the disk's path, of which formated by ext2 where file to be salvaged

`-t:` file types that need to be recovered, supports multiple salvage multiple types at a time, seperated by comma, ex: '-d pdf,mp4,txt'

`-s:` block_size_in_byte, the block size of file system 

`-p:` recover_path, the path where recovered file to put


### trial steps
```
1. prepare a LUN (virtual disk)

2. format the LUN with ext2 filesystem

3. mount the formated file-system

4. create/copy some test file into the filesystem

5. remove the test files

6. umount the filesystem

7. corrupt the superblock and other metatdata of the filesystem by 'dd' command

8. use salvage.pl to salvage the test files
```

