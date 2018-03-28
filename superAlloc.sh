elementsLarge=1000
elementsSmall=3500
echo "superalloc object times"
time $1 $elementsSmall 1 1 0 1
time $1 $elementsSmall 2 1 0 1
time $1 $elementsSmall 3 1 0 1
time $1 $elementsSmall 4 1 0 1
time $1 $elementsSmall 5 1 0 1
time $1 $elementsSmall 6 1 0 1
time $1 $elementsSmall 7 1 0 1
time $1 $elementsSmall 8 1 0 1

echo "superalloc array times"
time $1 $elementsLarge 1 1 1 0
time $1 $elementsLarge 2 1 1 0
time $1 $elementsLarge 3 1 1 0
time $1 $elementsLarge 4 1 1 0
time $1 $elementsLarge 5 1 1 0
time $1 $elementsLarge 6 1 1 0
time $1 $elementsLarge 7 1 1 0
time $1 $elementsLarge 8 1 1 0

