module std.experimental.allocator.building_blocks.aligned_block_list;

import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;

// Common function implementation for thread local and shared AlignedBlockList
private mixin template AlignedBlockListImpl(bool isShared)
{
    import std.traits : hasMember;
    import std.typecons : Ternary;
    static if (isShared)
    import core.internal.spinlock : SpinLock;

private:
    struct AlignedBlockNode
    {
        AlignedBlockNode *next;
        StatsCollector!(Allocator, Options.bytesUsed) bAlloc;
        uint keepAlive;
    }

    static if (stateSize!ParentAllocator) ParentAllocator parent;
    else alias parent = ParentAllocator.instance;

    AlignedBlockNode *root;

    static if (isShared)
    SpinLock lock = SpinLock(SpinLock.Contention.brief);

    private void moveToFront(AlignedBlockNode *tmp, AlignedBlockNode *prev)
    {
        auto localRoot = cast(AlignedBlockNode*) root;
        if (tmp == localRoot)
            return;

        prev.next = tmp.next;
        tmp.next = localRoot;

        root = cast(typeof(root)) tmp;
    }

    private void removeNode(AlignedBlockNode* tmp, AlignedBlockNode *prev)
    {
        AlignedBlockNode *next = tmp.next;

        if (prev)
            prev.next = next;
        assert(parent.deallocate((cast(void*) tmp)[0 .. alignment]));

        if (tmp == cast(AlignedBlockNode*) root)
            root = cast(typeof(root)) next;
    }

    private bool insertNewNode()
    {
        void[] buf = parent.alignedAllocate(alignment, alignment);
        if (buf is null)
            return false;

        auto localRoot = cast(AlignedBlockNode*) root;
        auto newNode = cast(AlignedBlockNode*) buf;
        ubyte[] payload = ((cast(ubyte*) buf[AlignedBlockNode.sizeof .. $])[0 .. buf.length - AlignedBlockNode.sizeof]);
        newNode.bAlloc.parent = Allocator(payload);

        if (localRoot)
            newNode.next = localRoot;
        else
            newNode.next = null;

        root = cast(typeof(root)) newNode;
        return true;
    }

public:
    enum ulong alignment = theAlignment;

    static if (hasMember!(ParentAllocator, "owns"))
    Ternary owns(void[] b)
    {
        return parent.owns(b);
    }

    bool deallocate(void[] b)
    {
        enum ulong mask = ~(alignment - 1);
        // Round buffer to nearest `alignment` multiple
        ulong ptr = ((cast(ulong) b.ptr) & mask);
        AlignedBlockNode *node = cast(AlignedBlockNode*) ptr;
        return node.bAlloc.deallocate(b);
    }

    static if (hasMember!(ParentAllocator, "alignedAllocate"))
    void[] allocate(size_t n)
    {
        static if (isShared)
        lock.lock();

        AlignedBlockNode *prev;
        auto tmp = cast(AlignedBlockNode*) root;

        // Iterate through list and find first node which has fresh memory available
        while (tmp)
        {
            static if (isShared)
            {
                tmp.keepAlive++;
                lock.unlock();
            }

            auto result = tmp.bAlloc.allocate(n);
            if (result.length == n)
            {
                static if (isShared)
                lock.lock();

                moveToFront(tmp, prev);

                static if (isShared)
                {
                    tmp.keepAlive--;
                    lock.unlock();
                }

                return result;
            }

            static if (isShared)
            {
                lock.lock();
                tmp.keepAlive--;
            }

            // This node has no fresh memory available doesn't hold alive objects, remove it
            if (tmp.bAlloc.bytesUsed == 0 && tmp.keepAlive == 0)
            {
                removeNode(tmp, prev);
                if (!root)
                    break;
            }

            prev = tmp;
            tmp = tmp.next;
        }

        if (!insertNewNode())
        {
            static if (isShared)
            lock.unlock();
            return null;
        }

        void[] result = (cast(AlignedBlockNode*) root).bAlloc.allocate(n);

        static if (isShared)
        lock.unlock();

        return result;
    }
}

version (StdDdoc)
{
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
    struct AlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 23))
    {
        import std.typecons : Ternary;
        import std.traits : hasMember;

        /**
        Returns a fresh chunk of memory of size `n`.
        It finds the first node in the `AlignedBlockNode` list which has available memory,
        and moves it to the front of the list.

        All empty nodes which cannot return new memory, are removed from the list.
        */
        static if (hasMember!(ParentAllocator, "alignedAllocate"))
        void[] allocate(size_t n);

        /**
        Marks for the given buffer for deallocation.
        The actual memory is deallocated only when all memory inside the corresponding
        `BitmappedBlock` is marked for deallocation.
        */
        bool deallocate(void[] b);

        /**
        Returns `Ternary.yes` if the buffer belongs to the parent allocator and
        `Ternary.no` otherwise.
        */
        static if (hasMember!(ParentAllocator, "owns"))
        Ternary owns(void[] b);
    }
}
else
{
    struct AlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 23))
    {
        mixin AlignedBlockListImpl!false;
    }
}

version (StdDdoc)
{
    /**
    `SharedAlignedBlockList` is the threadsafe version of `AlignedBlockList`
    */
    shared struct SharedAlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 23))
    {
        import std.typecons : Ternary;
        import std.traits : hasMember;

        /**
        Returns a fresh chunk of memory of size `n`.
        It finds the first node in the `AlignedBlockNode` list which has available memory,
        and moves it to the front of the list.

        All empty nodes which cannot return new memory, are removed from the list.
        */
        static if (hasMember!(ParentAllocator, "alignedAllocate"))
        void[] allocate(size_t n);

        /**
        Marks for the given buffer for deallocation.
        The actual memory is deallocated only when all memory inside the corresponding
        `BitmappedBlock` is marked for deallocation.
        */
        bool deallocate(void[] b);

        /**
        Returns `Ternary.yes` if the buffer belongs to the parent allocator and
        `Ternary.no` otherwise.
        */
        static if (hasMember!(ParentAllocator, "owns"))
        Ternary owns(void[] b);
    }
}
else
{
    shared struct SharedAlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 23))
    {
        mixin AlignedBlockListImpl!true;
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
            AlignedBlockList!(BitmappedBlock!16, AscendingPageAllocator*, 1 << 16),
            Segregator!(
                32,
                AlignedBlockList!(BitmappedBlock!32, AscendingPageAllocator*, 1 << 16),
                Segregator!(
                    64,
                    AlignedBlockList!(BitmappedBlock!64, AscendingPageAllocator*, 1 << 16),
                    Segregator!(
                        128,
                        AlignedBlockList!(BitmappedBlock!128, AscendingPageAllocator*, 1 << 16),
                        Segregator!(
                            256,
                            AlignedBlockList!(BitmappedBlock!256, AscendingPageAllocator*, 1 << 16),
                            Segregator!(
                                512,
                                AlignedBlockList!(BitmappedBlock!512, AscendingPageAllocator*, 1 << 16),
                                Segregator!(
                                    1024,
                                    AlignedBlockList!(BitmappedBlock!1024, AscendingPageAllocator*, 1 << 16),
                                    Segregator!(
                                        2048,
                                        AlignedBlockList!(BitmappedBlock!2048, AscendingPageAllocator*, 1 << 16),
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
    AscendingPageAllocator pageAlloc = AscendingPageAllocator(4096 * 4096);
    a.allocatorForSize!4096 = &pageAlloc;
    a.allocatorForSize!2048.parent = &pageAlloc;
    a.allocatorForSize!1024.parent = &pageAlloc;
    a.allocatorForSize!512.parent = &pageAlloc;
    a.allocatorForSize!256.parent = &pageAlloc;
    a.allocatorForSize!128.parent = &pageAlloc;
    a.allocatorForSize!64.parent = &pageAlloc;
    a.allocatorForSize!32.parent = &pageAlloc;
    a.allocatorForSize!16.parent = &pageAlloc;

    auto rnd = Random();

    size_t maxIter = 100;
    enum testNum = 10;
    void[][testNum] buf;
    size_t pageSize = 4096;
    int maxSize = 8192;
    for (int i = 0; i < maxIter; i += testNum)
    {
        foreach (j; 0 .. testNum)
        {
            auto size = uniform(1, maxSize + 1, rnd);
            buf[j] = a.allocate(size);
            assert(buf[j].length == size);
            testrw(buf[j]);
        }

        randomShuffle(buf[]);

        foreach (j; 0 .. testNum)
        {
            assert(a.deallocate(buf[j]));
        }
    }
}

/*
@system unittest
{
    import std.experimental.allocator.building_blocks.ascending_page_allocator : SharedAscendingPageAllocator;
    import std.experimental.allocator.building_blocks.segregator : Segregator;
    import std.random;
    import core.thread : ThreadGroup;
    import core.internal.spinlock : SpinLock;

    alias SuperAllocator = Segregator!(
            16,
            SharedAlignedBlockList!(BitmappedBlock!16, SharedAscendingPageAllocator*, 1 << 16),
            Segregator!(
                32,
                SharedAlignedBlockList!(BitmappedBlock!32, SharedAscendingPageAllocator*, 1 << 16),
                Segregator!(
                    64,
                    SharedAlignedBlockList!(BitmappedBlock!64, SharedAscendingPageAllocator*, 1 << 16),
                    Segregator!(
                        128,
                        SharedAlignedBlockList!(BitmappedBlock!128, SharedAscendingPageAllocator*, 1 << 16),
                        Segregator!(
                            256,
                            SharedAlignedBlockList!(BitmappedBlock!256, SharedAscendingPageAllocator*, 1 << 16),
                            Segregator!(
                                512,
                                SharedAlignedBlockList!(BitmappedBlock!512, SharedAscendingPageAllocator*, 1 << 16),
                                Segregator!(
                                    1024,
                                    SharedAlignedBlockList!(BitmappedBlock!1024, SharedAscendingPageAllocator*, 1 << 16),
                                    Segregator!(
                                        2048,
                                        SharedAlignedBlockList!(BitmappedBlock!2048, SharedAscendingPageAllocator*, 1 << 16),
                                        SharedAscendingPageAllocator*
                                    )
                                )
                            )
                        )
                    )
                )
            )
        );
    enum numThreads = 10;

    SuperAllocator a;
    shared SharedAscendingPageAllocator pageAlloc = SharedAscendingPageAllocator(4096 * 1024);
    a.allocatorForSize!4096 = &pageAlloc;
    a.allocatorForSize!2048.parent = &pageAlloc;
    a.allocatorForSize!1024.parent = &pageAlloc;
    a.allocatorForSize!512.parent = &pageAlloc;
    a.allocatorForSize!256.parent = &pageAlloc;
    a.allocatorForSize!128.parent = &pageAlloc;
    a.allocatorForSize!64.parent = &pageAlloc;
    a.allocatorForSize!32.parent = &pageAlloc;
    a.allocatorForSize!16.parent = &pageAlloc;

    void fun()
    {
        auto rnd = Random();

        size_t maxIter = 20;
        enum testNum = 5;
        void[][testNum] buf;
        size_t pageSize = 4096;
        int maxSize = 8192;
        for (int i = 0; i < maxIter; i += testNum)
        {
            foreach (j; 0 .. testNum)
            {
                auto size = uniform(1, maxSize + 1, rnd);
                buf[j] = a.allocate(size);
                assert(buf[j].length == size);
                testrw(buf[j]);
            }

            randomShuffle(buf[]);

            foreach (j; 0 .. testNum)
            {
                assert(a.deallocate(buf[j]));
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
*/

@system unittest
{
    import std.experimental.allocator.building_blocks.region : SharedRegion;
    import std.experimental.allocator.building_blocks.ascending_page_allocator : SharedAscendingPageAllocator;
    import std.random;
    import core.thread : ThreadGroup;
    import core.internal.spinlock : SpinLock;

    alias SuperAllocator = SharedAlignedBlockList!(SharedRegion, SharedAscendingPageAllocator, 1 << 16);
    enum numThreads = 10;

    SuperAllocator a;
    a.parent = SharedAscendingPageAllocator(4096 * 1024);

    void fun()
    {
        auto rnd = Random();

        size_t maxIter = 20;
        enum testNum = 5;
        void[][testNum] buf;
        size_t pageSize = 4096;
        int maxSize = 8192;
        for (int i = 0; i < maxIter; i += testNum)
        {
            foreach (j; 0 .. testNum)
            {
                auto size = uniform(1, maxSize + 1, rnd);
                buf[j] = a.allocate(size);
                assert(buf[j].length == size);
                testrw(buf[j]);
            }

            randomShuffle(buf[]);

            foreach (j; 0 .. testNum)
            {
                assert(a.deallocate(buf[j]));
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
