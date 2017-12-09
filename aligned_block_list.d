import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;
import std.experimental.allocator.building_blocks.ascending_page_allocator;
import std.experimental.allocator.building_blocks.segregator;

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
        auto tmp = root;
        while (tmp) 
        {
            auto result = tmp.bAlloc.allocateFresh(n);
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
                }
                return result;
            }

            tmp = tmp.next;
            if (tmp == root)
                break;
        }

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
    alias SuperAllocator = Segregator!(
            64,
            AlignedBlockList!(64, AscendingPageAllocator, 4096),
            AscendingPageAllocator);
    SuperAllocator a;
    a.allocatorForSize!100 = AscendingPageAllocator(4096);
    a.allocatorForSize!32.parent = AscendingPageAllocator(4096);
}

void main()
{
}
