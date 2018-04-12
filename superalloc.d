import std.experimental.allocator;
import std.datetime.stopwatch;
import std.experimental.allocator.building_blocks.aligned_block_list;
import std.experimental.allocator.building_blocks.bitmapped_block;
import std.experimental.allocator.building_blocks.region;
import std.experimental.allocator.building_blocks.ascending_page_allocator;
import std.experimental.allocator.mallocator;
import std.random;
import std.algorithm.sorting : sort;
import core.thread : ThreadGroup;
import core.internal.spinlock : SpinLock;
import std.conv : to;


void main(string[] args)
{
    import std.stdio;

    auto numNodes = args[1].to!int;
    auto numThreads = args[2].to!int;
    auto chooseAlloc = args[3].to!int;
    auto largeTest = args[4].to!int;
    auto smallTest = args[5].to!int;

    void fun()
    {
        struct MediumStruct
        {
            int[1 << 15] arr;
        }

        alias T = MediumStruct;

        ThreadLocalAllocator tlAlloc;
        alias tlMalloc = Mallocator.instance;

        auto rnd = Random(1000);
        T[][] largeAllocs = (cast(T[][]) Mallocator.instance.allocate(numNodes * (T[]).sizeof))[0 .. numNodes];
        T*[] smallAllocs = (cast(T*[]) Mallocator.instance.allocate(numNodes * size_t.sizeof))[0 .. numNodes];


        if (smallTest)
        {
            for (int i = 0; i < numNodes; i++)
            {
                for (int j = 0; j < numNodes; j++)
                {
                    if (chooseAlloc)
                        smallAllocs[j] = tlAlloc.make!T;
                    else
                        smallAllocs[j] = tlMalloc.make!T;
                    smallAllocs[j].arr[0] = j;
                }

                for (int j = 0; j < numNodes; j++)
                {
                    assert(smallAllocs[j].arr[i] == j);
                    if (chooseAlloc)
                        tlAlloc.dispose(smallAllocs[j]);
                    else
                        tlMalloc.dispose(smallAllocs[j]);
                }
            }
        }

        if (largeTest)
        {
            for (int i = 0; i < numNodes; i++)
            {
                for (int j = 0; j < numNodes; j++)
                {
                    int arrSize = uniform(5, 15, rnd);
                    if (chooseAlloc)
                        largeAllocs[j] = tlAlloc.makeArray!T(arrSize);

                    else
                        largeAllocs[j] = tlMalloc.makeArray!T(arrSize);
                }

                for (int j = 0; j < numNodes; j++)
                {
                    if (chooseAlloc)
                        tlAlloc.dispose(largeAllocs[j]);
                    else
                        tlMalloc.dispose(largeAllocs[j]);
                }
            }
        }
    }

    auto tg = new ThreadGroup;
    foreach (i; 0 .. numThreads)
    {
        tg.create(&fun);
    }
    tg.joinAll();
}

