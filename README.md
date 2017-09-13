# ext2salvage

Salvage files from either corrupted ext2 file system or accidental deletion


**_usage_**
```
perl salvage.pl -d disk-path -t file-type -s block-size -p recover-path
```


**_parameters_**

`-h:` : help 

`-d`  : disk-path, the disk's path, of which formated by ext2 filesystem where file(s) to be salvaged from

`-t`  : file-types that need to be recovered, supports multiple salvage multiple types at a time, each type was seperated by comma, ex: pdf,mp4,txt

`-s`  : block-size-in-byte, the block size of file system 

`-p`  : recover-path, the directory where salvaged file(s) to be placed to


**_example_**

Salvage all pdf, mp4 and txt files which were deleted accidentally from disk /dev/sdc1
```
$ perl -d /dev/sdc1 -t pdf,mp4,txt -p ./refund/
```


**_trial steps_**
```
1. prepare a LUN (or virtual disk)
2. format the LUN with ext2 filesystem
3. mount the formated filesystem
4. create/copy some test file into the filesystem
5. remove the test files
6. umount the filesystem
7. corrupt the superblock and other metatdata of the filesystem by 'dd' command
8. use salvage.pl to salvage the test files
```

