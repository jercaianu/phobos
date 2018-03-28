elementsLarge=1000
elementsSmall=3500
echo "malloc object times"
time $1 $elementsSmall 1 0 0 1
time $1 $elementsSmall 2 0 0 1
time $1 $elementsSmall 3 0 0 1
time $1 $elementsSmall 4 0 0 1
time $1 $elementsSmall 5 0 0 1
time $1 $elementsSmall 6 0 0 1
time $1 $elementsSmall 7 0 0 1
time $1 $elementsSmall 8 0 0 1

echo "malloc array times"
time $1 $elementsLarge 1 0 1 0
time $1 $elementsLarge 2 0 1 0
time $1 $elementsLarge 3 0 1 0
time $1 $elementsLarge 4 0 1 0
time $1 $elementsLarge 5 0 1 0
time $1 $elementsLarge 6 0 1 0
time $1 $elementsLarge 7 0 1 0
time $1 $elementsLarge 8 0 1 0
