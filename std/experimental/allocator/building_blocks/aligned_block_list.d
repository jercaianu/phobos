module std.experimental.allocator.building_blocks.aligned_block_list;

import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.building_blocks.region;
import std.datetime.stopwatch;

enum timeDbg = 0;


StopWatch swPageAlloc;
StopWatch swBitAlloc;
StopWatch swFastTrack;
StopWatch swSlowTrack;

int repeatLoop = 0;

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
        AlignedBlockNode* next, prev;
        Allocator bAlloc;

        static if (isShared)
        {
            shared(size_t) bytesUsed;
            uint keepAlive;
        }
        else
        {
            size_t bytesUsed;
        }
    }

    static if (stateSize!ParentAllocator) ParentAllocator parent;
    else alias parent = ParentAllocator.instance;

    AlignedBlockNode *root;
    int numNodes;

    static if (isShared)
    SpinLock lock = SpinLock(SpinLock.Contention.brief);

    private void moveToFront(AlignedBlockNode *tmp)
    {
        auto localRoot = cast(AlignedBlockNode*) root;
        if (tmp == localRoot)
            return;

        if (tmp.prev) tmp.prev.next = tmp.next;
        if (tmp.next) tmp.next.prev = tmp.prev;
        if (localRoot) localRoot.prev = tmp;
        tmp.next = localRoot;
        tmp.prev = null;

        root = cast(typeof(root)) tmp;
    }

    private void removeNode(AlignedBlockNode* tmp)
    {
        static if (isShared)
        import core.atomic : atomicOp;

        auto next = tmp.next;
        if (tmp.prev) tmp.prev.next = tmp.next;
        if (tmp.next) tmp.next.prev = tmp.prev;
        assert(parent.deallocate((cast(void*) tmp)[0 .. alignment]));

        if (tmp == cast(AlignedBlockNode*) root)
            root = cast(typeof(root)) next;

        static if (isShared)
        {
            atomicOp!"-="(numNodes, 1);
        }
        else
        {
            numNodes--;
        }
    }

    private bool insertNewNode()
    {
        static if (isShared)
        import core.atomic : atomicOp;

        void[] buf = parent.alignedAllocate(alignment, alignment);
        if (buf is null)
            return false;

        auto localRoot = cast(AlignedBlockNode*) root;
        auto newNode = cast(AlignedBlockNode*) buf;
        static if (timeDbg)
        swPageAlloc.start();
        ubyte[] payload = ((cast(ubyte*) buf[AlignedBlockNode.sizeof .. $])[0 .. buf.length - AlignedBlockNode.sizeof]);
        newNode.bAlloc = Allocator(payload);
        static if (timeDbg)
        swPageAlloc.stop();

        newNode.next = localRoot;
        newNode.prev = null;
        if (localRoot)
            localRoot.prev = newNode;
        root = cast(typeof(root)) newNode;

        static if (isShared)
        {
            atomicOp!"+="(numNodes, 1);
        }
        else
        {
            numNodes++;
        }

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
        static if (isShared)
        import core.atomic : atomicOp;

        enum ulong mask = ~(alignment - 1);
        // Round buffer to nearest `alignment` multiple
        ulong ptr = ((cast(ulong) b.ptr) & mask);
        AlignedBlockNode *node = cast(AlignedBlockNode*) ptr;
        if (node.bAlloc.deallocate(b))
        {
            static if (isShared)
            {
                atomicOp!"-="(node.bytesUsed, b.length);
            }
            else
            {
                node.bytesUsed -= b.length;
            }
            return true;
        }
        return false;
    }

    static if (hasMember!(ParentAllocator, "alignedAllocate"))
    void[] allocate(size_t n)
    {
        static if (isShared)
        import core.atomic : atomicOp, atomicLoad;

        if (n == 0 || n > alignment)
            return null;

        static if (isShared)
        lock.lock();

        auto tmp = cast(AlignedBlockNode*) root;

        // Iterate through list and find first node which has fresh memory available
        int loopCount = 0;
        while (tmp)
        {
            loopCount++;
            if (loopCount == 2)
                repeatLoop++;
            static if (isShared)
            {
                tmp.keepAlive++;
                lock.unlock();
            }

            static if (timeDbg)
            swBitAlloc.start();
            auto result = tmp.bAlloc.allocate(n);
            static if (timeDbg)
            swBitAlloc.stop();

            static if (timeDbg)
            swFastTrack.start();

            if (result.length == n)
            {
                static if (isShared)
                {
                    atomicOp!"+="(tmp.bytesUsed, n);
                    lock.lock();
                }
                else
                {
                    tmp.bytesUsed += n;
                }

                moveToFront(tmp);

                static if (isShared)
                {
                    tmp.keepAlive--;
                    lock.unlock();
                }
                static if (timeDbg)
                swFastTrack.stop();

                return result;
            }

            static if (isShared)
            {
                lock.lock();
                tmp.keepAlive--;
            }

            // This node has no fresh memory available doesn't hold alive objects, remove it
            static if (isShared)
            {
                if (atomicLoad(numNodes) > 10 &&
                    atomicLoad(tmp.bytesUsed) == 0 &&
                    tmp.keepAlive == 0)
                {
                    removeNode(tmp);
                    if (!root)
                        break;
                }
            }
            else
            {
                if (numNodes > 10 && tmp.bytesUsed == 0)
                {
                    removeNode(tmp);
                    if (!root)
                        break;
                }
            }

            tmp = tmp.next;
            static if (timeDbg)
            swFastTrack.stop();
        }

        if (!insertNewNode())
        {
            static if (isShared)
            lock.unlock();

            static if (timeDbg)
            swFastTrack.stop();
            return null;
        }


        static if (timeDbg)
        swFastTrack.stop();

        static if (timeDbg)
        swBitAlloc.start();
        void[] result = (cast(AlignedBlockNode*) root).bAlloc.allocate(n);
        static if (timeDbg)
        swBitAlloc.stop();

        static if (isShared)
        {
            atomicOp!"+="(root.bytesUsed, result.length);
            lock.unlock();
        }
        else
        {
            root.bytesUsed += result.length;
        }

        return result;
    }

    size_t goodAllocSize(const size_t n)
    {
        Allocator a = null;
        return a.goodAllocSize(n);
    }
}

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
    version (StdDdoc)
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
    else
    {
        mixin AlignedBlockListImpl!false;
    }
}

/**
`SharedAlignedBlockList` is the threadsafe version of `AlignedBlockList`
*/
shared struct SharedAlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 23))
{
    version (StdDdoc)
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
    else
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
    );

    SuperAllocator a;
    auto pageAlloc = AscendingPageAllocator(4096 * 4096);
    a.allocatorForSize!4096 = &pageAlloc;
    a.allocatorForSize!2048.parent = &pageAlloc;
    a.allocatorForSize!1024.parent = &pageAlloc;
    a.allocatorForSize!512.parent = &pageAlloc;
    a.allocatorForSize!256.parent = &pageAlloc;

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

@system unittest
{
    import std.experimental.allocator.building_blocks.ascending_page_allocator : SharedAscendingPageAllocator;
    import std.experimental.allocator.building_blocks.segregator : Segregator;
    import std.random;
    import core.thread : ThreadGroup;
    import core.internal.spinlock : SpinLock;

    alias SuperAllocator = Segregator!(
        256,
        SharedAlignedBlockList!(SharedBitmappedBlock!256, SharedAscendingPageAllocator*, 1 << 16),
        Segregator!(
            512,
            SharedAlignedBlockList!(SharedBitmappedBlock!512, SharedAscendingPageAllocator*, 1 << 16),
            Segregator!(
                1024,
                SharedAlignedBlockList!(SharedBitmappedBlock!1024, SharedAscendingPageAllocator*, 1 << 16),
                Segregator!(
                    2048,
                    SharedAlignedBlockList!(SharedBitmappedBlock!2048, SharedAscendingPageAllocator*, 1 << 16),
                    SharedAscendingPageAllocator*
                )
            )
        )
    );
    enum numThreads = 10;

    SuperAllocator a;
    auto pageAlloc = SharedAscendingPageAllocator(4096 * 1024);
    a.allocatorForSize!4096 = &pageAlloc;
    a.allocatorForSize!2048.parent = &pageAlloc;
    a.allocatorForSize!1024.parent = &pageAlloc;
    a.allocatorForSize!512.parent = &pageAlloc;
    a.allocatorForSize!256.parent = &pageAlloc;

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

@system unittest
{
    import std.experimental.allocator.building_blocks.region;
    import std.experimental.allocator.building_blocks.ascending_page_allocator;
    import std.random;
    import std.algorithm.sorting : sort;
    import core.thread : ThreadGroup;
    import core.internal.spinlock : SpinLock;

    enum pageSize = 4096;
    enum numThreads = 10;
    enum maxIter = 20;
    enum totalAllocs = maxIter * numThreads;
    size_t count = 0;
    SpinLock lock = SpinLock(SpinLock.Contention.brief);

    alias SuperAllocator = SharedAlignedBlockList!(SharedRegion!(NullAllocator, 1), SharedAscendingPageAllocator, 1 << 16);
    void[][totalAllocs] buf;

    SuperAllocator a;
    a.parent = SharedAscendingPageAllocator(4096 * 1024);

    void fun()
    {
        auto rnd = Random();

        foreach(i; 0 .. maxIter)
        {
            auto size = uniform(1, pageSize + 1, rnd);
            void[] b = a.allocate(size);
            assert(b.length == size);
            testrw(b);

            lock.lock();
            buf[count++] = b;
            lock.unlock();
        }
    }
    auto tg = new ThreadGroup;
    foreach (i; 0 .. numThreads)
    {
        tg.create(&fun);
    }
    tg.joinAll();

    sort!((a, b) => a.ptr < b.ptr)(buf[0 .. totalAllocs]);
    foreach (i; 0 .. totalAllocs - 1)
    {
        assert(buf[i].ptr + a.goodAllocSize(buf[i].length) <= buf[i + 1].ptr);
    }

    foreach (i; 0 .. totalAllocs)
    {
        assert(a.deallocate(buf[totalAllocs - 1 - i]));
    }
}

/*
void main()
{
    import std.experimental.allocator.building_blocks.ascending_page_allocator;
    import std.experimental.allocator.building_blocks.segregator;
    import std.experimental.allocator.mallocator;
    import std.random;
    import core.thread : ThreadGroup;
    import core.internal.spinlock : SpinLock;
    import std.stdio;

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

    alias SharedBitmappedBlock = BitmappedBlock2;
    alias SharedAscendingPageAllocator = AscendingPageAllocator;
    alias SharedAlignedBlockList = AlignedBlockList;
    alias SuperAllocator = Segregator!(
        8,
        SharedAlignedBlockList!(SharedBitmappedBlock!8, SharedAscendingPageAllocator*, 1 << 12),
        Segregator!(

        16,
        SharedAlignedBlockList!(SharedBitmappedBlock!16, SharedAscendingPageAllocator*, 1 << 12),
        Segregator!(

        32,
        SharedAlignedBlockList!(SharedBitmappedBlock!32, SharedAscendingPageAllocator*, 1 << 13),
        Segregator!(

        64,
        SharedAlignedBlockList!(SharedBitmappedBlock!64, SharedAscendingPageAllocator*, 1 << 14),
        Segregator!(

        128,
        SharedAlignedBlockList!(SharedBitmappedBlock!128, SharedAscendingPageAllocator*, 1 << 15),
        Segregator!(

        256,
        SharedAlignedBlockList!(SharedBitmappedBlock!256, SharedAscendingPageAllocator*, 1 << 16),
        Segregator!(

        512,
        SharedAlignedBlockList!(SharedBitmappedBlock!512, SharedAscendingPageAllocator*, 1 << 17),
        Segregator!(

        1024,
        SharedAlignedBlockList!(SharedBitmappedBlock!1024, SharedAscendingPageAllocator*, 1 << 18),
        Segregator!(

        2048,
        SharedAlignedBlockList!(SharedBitmappedBlock!2048, SharedAscendingPageAllocator*, 1 << 19),
        Segregator!(

        1 << 12,
        SharedAlignedBlockList!(SharedBitmappedBlock!(1 << 12), SharedAscendingPageAllocator*, 1 << 20),
        Segregator!(

        1 << 13,
        SharedAlignedBlockList!(SharedBitmappedBlock!(1 << 13), SharedAscendingPageAllocator*, 1 << 21),
        Segregator!(

        1 << 14,
        SharedAlignedBlockList!(SharedBitmappedBlock!(1 << 14), SharedAscendingPageAllocator*, 1 << 22),
        Segregator!(

        1 << 15,
        SharedAlignedBlockList!(SharedBitmappedBlock!(1 << 15), SharedAscendingPageAllocator*, 1 << 23),
        SharedAscendingPageAllocator*
        )))))))))))));

    enum myAlloc = 0;
    static if (myAlloc)
    {
        SuperAllocator a;
        auto pageAlloc = SharedAscendingPageAllocator(1UL << 40);
        a.allocatorForSize!(1 << 16) = &pageAlloc;
        a.allocatorForSize!(1 << 15).parent = &pageAlloc;
        a.allocatorForSize!(1 << 14).parent = &pageAlloc;
        a.allocatorForSize!(1 << 13).parent = &pageAlloc;
        a.allocatorForSize!(1 << 12).parent = &pageAlloc;
        a.allocatorForSize!2048.parent = &pageAlloc;
        a.allocatorForSize!1024.parent = &pageAlloc;
        a.allocatorForSize!512.parent = &pageAlloc;
        a.allocatorForSize!256.parent = &pageAlloc;
        a.allocatorForSize!128.parent = &pageAlloc;
        a.allocatorForSize!64.parent = &pageAlloc;
        a.allocatorForSize!32.parent = &pageAlloc;
        a.allocatorForSize!16.parent = &pageAlloc;
        a.allocatorForSize!8.parent = &pageAlloc;
    }
    else
    {
        alias a = Mallocator.instance;
    }

    auto rnd = Random(1000);
    auto swDirty = StopWatch(AutoStart.no);
    auto swDealloc = StopWatch(AutoStart.no);
    auto swShuffle = StopWatch(AutoStart.no);
    swBitAlloc = StopWatch(AutoStart.no);
    swPageAlloc = StopWatch(AutoStart.no);
    swFastTrack = StopWatch(AutoStart.no);
    swFastTrack.reset();

    size_t maxIter = 10000;
    enum testNum = 10000;
    void[][testNum] buf;
    size_t pageSize = 4096;
    for (int i = 0; i < maxIter; i ++)
    {
        foreach (j; 0 .. testNum)
        {
            size_t size;
            auto allocationType = uniform(7, 10, rnd);
            if (allocationType <= 6) size = uniform(3, 7, rnd);
            else if (allocationType <= 9) size = uniform(7, 16, rnd);
            else size = 17;

            buf[j] = a.allocate(1 << size);

            assert(buf[j].length == (1 << size));

            static if (timeDbg)
            swDirty.start();
            testrw(buf[j]);
            static if (timeDbg)
            swDirty.stop();
        }

        static if (timeDbg)
        swShuffle.start();
        randomShuffle(buf[]);
        static if (timeDbg)
        swShuffle.stop();

        static if (timeDbg)
        swDealloc.start();
        foreach (j; 0 .. testNum)
        {
            assert(a.deallocate(buf[j]));
        }
        static if (timeDbg)
        swDealloc.stop();
    }

    static if (timeDbg)
    {
        writeln("FastTrack time totals: ", swFastTrack.peek().toString());
        writeln("Deallocation time totals: ", swDealloc.peek().toString());
        writeln("Dirty time totals: ", swDirty.peek().toString());
        writeln("BitmappedBlock time totals: ", swBitAlloc.peek().toString());
        writeln("AscendingPage time totals: ", swPageAlloc.peek().toString());
    }
    writeln("Percentage of retries is: ", (cast(double) repeatLoop) / (testNum * maxIter));

}
*/
