./superAlloc.sh ./superalloc16 &> TIMES/super_16
cat TIMES/super_16 | grep -E "real|super" > TIMES/super_16f
./superAlloc.sh ./superalloc64 &> TIMES/super_64
cat TIMES/super_64 | grep -E "real|super" > TIMES/super_64f
./superAlloc.sh ./superalloc512 &> TIMES/super_512
cat TIMES/super_512 | grep -E "real|super" > TIMES/super_512f
./superAlloc.sh ./superalloc4096 &> TIMES/super_4096
cat TIMES/super_4096 | grep -E "real|super" > TIMES/super_4096f
