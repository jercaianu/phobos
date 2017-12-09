import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;
import std.experimental.allocator.building_blocks.ascending_page_allocator;
import std.experimental.allocator.building_blocks.segregator;

 @safe @nogc nothrow pure
 size_t roundUpToMultipleOf(size_t s, uint base)
 {
     assert(base);
     auto rem = s % base;
     return rem ? s + base - rem : s;
 }

struct AlignedBlockList(size_t blockSize, ParentAllocator, size_t theAlignment = (1 << 23))
{
    import std.traits : hasMember;

    struct AlignedBlockNode
    {
        AlignedBlockNode* next, prev;
        StatsCollector!(BitmappedBlock!(blockSize), Options.bytesUsed) bAlloc;
    }

    AlignedBlockNode *root;
    ParentAllocator parent;
    enum alignment = theAlignment;
    enum mask = ~(alignment - 1);

    static if (hasMember!(ParentAllocator, "alignedAllocate"))
    void[] allocate(size_t n)
    {
        import std.stdio;
        auto tmp = root;
        while (tmp)
        {
            auto result = tmp.bAlloc.allocateFresh(n);
            writeln("size occupied ", tmp.bAlloc.bytesUsed);
            if (result.length == n)
            {
                if (tmp != root)
                {
                    tmp.prev.next = tmp.next;
                    tmp.next.prev = tmp.prev;

                    tmp.next = root;
                    tmp.prev = root.prev;
                    root.prev.next = tmp;
                    root.prev = tmp;

                    root = tmp;
                }
                return result;
            }

            writeln("this block has no mem");
            AlignedBlockNode *next = tmp.next;
            if (tmp.bAlloc.bytesUsed == 0)
            {
                if (tmp == root)
                {
                    tmp.prev.next = tmp.next;
                    tmp.next.prev = tmp.prev;
                }
                assert(parent.deallocate((cast(void*) tmp)[0 .. alignment]));
                if (next == tmp)
                {
                    root = null;
                    break;
                }
                else
                    root = next;
            }
            if (next == root)
                break;

            tmp = next;
        }
        writeln("need new block");
        void[] buf = parent.alignedAllocate(alignment, alignment);
        if (!buf)
            return null;
        AlignedBlockNode *newNode = cast(AlignedBlockNode*) buf;
        newNode.bAlloc.parent = BitmappedBlock!(blockSize)((cast(ubyte*) buf[AlignedBlockNode.sizeof .. $])[0 .. buf.length - AlignedBlockNode.sizeof]);
        if (root)
        {
            newNode.next = root;
            root.prev.next = newNode;
            newNode.prev = root.prev;
            root.prev = newNode;
        }
        else
        {
            newNode.next = newNode;
            newNode.prev = newNode;
        }
        root = newNode;
        return root.bAlloc.allocateFresh(n);
    }

    bool deallocate(void[] b)
    {
        ulong ptr = ((cast(ulong) b.ptr) & mask);
        AlignedBlockNode *node = cast(AlignedBlockNode*) ptr;
        return node.bAlloc.deallocate(b);
    }
}

@system unittest
{
    void[][1000] buf;
    AlignedBlockList!(64, AscendingPageAllocator, 4096) a;
    a.parent = AscendingPageAllocator(4096);

    int i = 0;
    while(true) {
        void[] b = a.allocate(64);
        if (!b)
            break;
        assert(b.length == 64);
        buf[i] = b;
        i++;
    }

    for (int j = 0; j < i; j++)
        a.deallocate(buf[j]);
}

@system unittest
{
    static void testrw(void[] b)
    {
        ubyte* buf = cast(ubyte*) b.ptr;
        buf[0] = 100;
        assert(buf[0] == 100);
        buf[b.length - 1] = 101;
        assert(buf[b.length - 1] == 101);
    }
    alias SuperAllocator = Segregator!(
            64,
            AlignedBlockList!(64, AscendingPageAllocator*),
            Segregator!(
                128,
                AlignedBlockList!(128, AscendingPageAllocator*),
                Segregator!(
                    256,
                    AlignedBlockList!(256, AscendingPageAllocator*),
                    Segregator!(
                        512,
                        AlignedBlockList!(512, AscendingPageAllocator*),
                        Segregator!(
                            1024,
                            AlignedBlockList!(1024, AscendingPageAllocator*),
                            Segregator!(
                                2048,
                                AlignedBlockList!(2048, AscendingPageAllocator*),
                                AscendingPageAllocator*
                            )
                        )
                    )
                )
            )
        );

    SuperAllocator a;
    AscendingPageAllocator pageAlloc = AscendingPageAllocator(4096 * 1024 * 256);
    a.allocatorForSize!4096 = &pageAlloc;
    a.allocatorForSize!2048.parent = &pageAlloc;
    a.allocatorForSize!1024.parent = &pageAlloc;
    a.allocatorForSize!512.parent = &pageAlloc;
    a.allocatorForSize!256.parent = &pageAlloc;
    a.allocatorForSize!128.parent = &pageAlloc;
    a.allocatorForSize!64.parent = &pageAlloc;

    import std.stdio;
    ulong[] sizes = [64, 128, 256, 512, 1024, 2048, 4096];
    for (int i = 0; i < sizes.length - 1; i++)
    {
        //void* oldOffset = pageAlloc.offset;
        void[] b = a.allocate(sizes[i]);
        //if (i == sizes - 1) assert (pageAlloc.offset - oldOffset == 4096);
        //else assert(pageAlloc.offset - oldOffset == (1 << 23));
        writeln(b.ptr);
        assert(b.length == sizes[i]);
        testrw(b);
    }
}

void main()
{
     import std.experimental.allocator.mallocator : Mallocator;
     static void testrw(void[] b)
     {
         ubyte* buf = cast(ubyte*) b.ptr;
         size_t len = (b.length).roundUpToMultipleOf(4096);
         for (int i = 0; i < len; i += 4096)
         {
             buf[i] =  (cast(ubyte)i % 256);
             assert(buf[i] == (cast(ubyte)i % 256));
         }
     }

     alias SuperAllocator = Segregator!(
             64,
             AlignedBlockList!(64, AscendingPageAllocator*),
             Segregator!(
                 128,
                 AlignedBlockList!(128, AscendingPageAllocator*),
                 Segregator!(
                     256,
                     AlignedBlockList!(256, AscendingPageAllocator*),
                     Segregator!(
                         512,
                         AlignedBlockList!(512, AscendingPageAllocator*),
                         Segregator!(
                             1024,
                             AlignedBlockList!(1024, AscendingPageAllocator*),
                             Segregator!(
                                 2048,
                                 AlignedBlockList!(2048, AscendingPageAllocator*),
                                 AscendingPageAllocator*
                             )
                         )
                     )
                 )
             )
         );

     SuperAllocator a;
     size_t maxCapacity = 2621000000UL * 4096UL;
     AscendingPageAllocator pageAlloc = AscendingPageAllocator(maxCapacity);
     a.allocatorForSize!4096 = &pageAlloc;
     a.allocatorForSize!2048.parent = &pageAlloc;
     a.allocatorForSize!1024.parent = &pageAlloc;
     a.allocatorForSize!512.parent = &pageAlloc;
     a.allocatorForSize!256.parent = &pageAlloc;
     a.allocatorForSize!128.parent = &pageAlloc;
     a.allocatorForSize!64.parent = &pageAlloc;

     ulong[] sizes = [64, 128, 256, 512, 1024, 2048, 4096 * 100];

     import std.random;
     auto rnd = Random(1000);

     size_t numPages = 2100000;
     enum testNum = 10000;
     size_t numAlloc = 10;
     void[][testNum] buf;
     size_t pageSize = 4096;
     //AscendingPageAllocator a = AscendingPageAllocator(maxCapacity);
     //alias a = Mallocator.instance;
     for (int i = 0; i < numPages; i += testNum)
     {
         for (int j = 0; j < testNum; j++)
         {
             auto ind = uniform(sizes.length - 2, sizes.length - 1, rnd);
             buf[j] = a.allocate(sizes[ind]);
             assert(buf[j].length == sizes[ind]);
             testrw(buf[j]);
         }

         randomShuffle(buf[]);

         for (int j = 0; j < testNum; j++)
         {
             assert(a.deallocate(buf[j]));
         }
     }
 }
