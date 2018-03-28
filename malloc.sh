./testMalloc.sh ./superalloc16 &> TIMES/malloc_16
cat TIMES/malloc_16 | grep -E "real|malloc" > TIMES/malloc_16f
./testMalloc.sh ./superalloc64 &> TIMES/malloc_64
cat TIMES/malloc_64 | grep -E "real|malloc" > TIMES/malloc_64f
./testMalloc.sh ./superalloc512 &> TIMES/malloc_512
cat TIMES/malloc_512 | grep -E "real|malloc" > TIMES/malloc_512f
#./testMalloc.sh ./superalloc4096 &> TIMES/malloc_4096
#cat TIMES/malloc_4096 | grep -E "real|malloc" > TIMES/malloc_4096f
