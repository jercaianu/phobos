dmd2 superalloc.d
elementsLarge=1000
elementsSmall=3500
echo "malloc object times"
time ./superalloc $elementsSmall 1 0 0 1
time ./superalloc $elementsSmall 2 0 0 1
time ./superalloc $elementsSmall 4 0 0 1
time ./superalloc $elementsSmall 8 0 0 1

echo "malloc array times"
time ./superalloc $elementsLarge 1 0 1 0
time ./superalloc $elementsLarge 2 0 1 0
time ./superalloc $elementsLarge 4 0 1 0
time ./superalloc $elementsLarge 8 0 1 0

echo "superalloc object times"
time ./superalloc $elementsSmall 1 1 0 1
time ./superalloc $elementsSmall 2 1 0 1
time ./superalloc $elementsSmall 4 1 0 1
time ./superalloc $elementsSmall 8 1 0 1

echo "superalloc array times"
time ./superalloc $elementsLarge 1 1 1 0
time ./superalloc $elementsLarge 2 1 1 0
time ./superalloc $elementsLarge 4 1 1 0
time ./superalloc $elementsLarge 8 1 1 0

