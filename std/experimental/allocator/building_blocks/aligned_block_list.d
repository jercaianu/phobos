module std.experimental.allocator.building_blocks.aligned_block_list;

import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;

/**
`AlignedBlockList` is a safe and fast allocator for small objects, under certain constraints.
If `ParentAllocator` implements `alignedAllocate`, and always returns fresh memory,
`AlignedBlockList` will eliminate undefined behaviour (by not reusing memory),
at the cost of higher fragmentation.

The allocator holds internally a doubly linked list of `BitmappedBlock`, which will serve allocations
in a most-recently-used fashion. Most recent allocators used for `allocate` calls, will be
moved to the front of the list.

Although allocations are in theory served in linear searching time, `deallocate` calls take
$(BIGOH 1) time, by using aligned allocations. All `BitmappedBlock` are allocated at the alignment given
as template parameter `theAlignment`. For a given pointer, this allows for quickly finding
the `BitmappedBlock` owner using basic bitwise operations. The recommended alignment is 4MB or 8MB.

The ideal use case for this allocator is in conjunction with `AscendingPageAllocator`, which
always returns fresh memory on aligned allocations and `Segregator` for multiplexing across a wide
range of block sizes.
*/
struct AlignedBlockList(size_t blockSize, ParentAllocator, ulong theAlignment = (1 << 23))
{
    import std.traits : hasMember;
    import std.typecons : Ternary;

    struct AlignedBlockNode
    {
        AlignedBlockNode* next, prev;
        StatsCollector!(BitmappedBlock!(blockSize), Options.bytesUsed) bAlloc;
    }

    static if (stateSize!ParentAllocator) ParentAllocator parent;
    else alias parent = ParentAllocator.instance;

    AlignedBlockNode *root;

    enum ulong alignment = theAlignment;
    enum ulong mask = ~(alignment - 1);

    private void moveToFront(AlignedBlockNode* tmp)
    {
        if (tmp == root)
            return;

        tmp.prev.next = tmp.next;
        tmp.next.prev = tmp.prev;

        tmp.next = root;
        tmp.prev = root.prev;
        root.prev.next = tmp;
        root.prev = tmp;

        root = tmp;
    }

    private void removeNode(AlignedBlockNode* tmp)
    {
        AlignedBlockNode *next = tmp.next;

        tmp.prev.next = tmp.next;
        tmp.next.prev = tmp.prev;
        assert(parent.deallocate((cast(void*) tmp)[0 .. alignment]));

        if (tmp == root)
        {
            // There is only one node
            if (next == tmp)
            {
                root = null;
            }
            else
            {
                root = next;
            }
        }
    }

    private bool insertNewNode()
    {
        void[] buf = parent.alignedAllocate(alignment, alignment);
        if (!buf)
            return false;

        AlignedBlockNode* newNode = cast(AlignedBlockNode*) buf;
        ubyte[] payload = ((cast(ubyte*) buf[AlignedBlockNode.sizeof .. $])[0 .. buf.length - AlignedBlockNode.sizeof]);
        newNode.bAlloc.parent = BitmappedBlock!(blockSize)(payload);

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
        return true;
    }

    static if (hasMember!(ParentAllocator, "alignedAllocate"))
    void[] allocate(size_t n)
    {
        import std.stdio;
        if (root)
        {
            auto tmp = root;
            while (true)
            {
                auto result = tmp.bAlloc.allocateFresh(n);
                if (result.length == n)
                {
                    moveToFront(tmp);
                    return result;
                }

                AlignedBlockNode *next = tmp.next;
                if (tmp.bAlloc.bytesUsed == 0)
                {
                    removeNode(tmp);
                    if (!root)
                        break;
                }

                // Reached the end of the list
                if (next == root)
                    break;

                tmp = next;
            }
        }

        if (!insertNewNode())
            return null;

        return root.bAlloc.allocateFresh(n);
    }

    bool deallocate(void[] b)
    {
        ulong ptr = ((cast(ulong) b.ptr) & mask);
        AlignedBlockNode *node = cast(AlignedBlockNode*) ptr;
        return node.bAlloc.deallocate(b);
    }

    static if (hasMember!(ParentAllocator, "owns"))
    Ternary owns(void[] b)
    {
        return parent.owns(b);
    }
}

version (unittest)
{
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
}

@system unittest
{
    import std.experimental.allocator.building_blocks.ascending_page_allocator : AscendingPageAllocator;
    import std.experimental.allocator.building_blocks.segregator : Segregator;
    import std.random;

    alias SuperAllocator = Segregator!(
            16,
            AlignedBlockList!(16, AscendingPageAllocator*),
            Segregator!(
                32,
                AlignedBlockList!(32, AscendingPageAllocator*),
                Segregator!(
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
    a.allocatorForSize!32.parent = &pageAlloc;
    a.allocatorForSize!16.parent = &pageAlloc;

    auto rnd = Random(1000);

    size_t maxIter = 10000;
    enum testNum = 100;
    void[][testNum] buf;
    size_t pageSize = 4096;
    int maxSize = 8192;
    for (int i = 0; i < maxIter; i += testNum)
    {
        for (int j = 0; j < testNum; j++)
        {
            auto size = uniform(1, maxSize + 1, rnd);
            buf[j] = a.allocate(size);
            assert(buf[j].length == size);
            testrw(buf[j]);
        }

        randomShuffle(buf[]);

        for (int j = 0; j < testNum; j++)
        {
            assert(a.deallocate(buf[j]));
        }
    }
}
