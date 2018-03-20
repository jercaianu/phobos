module std.experimental.allocator.building_blocks.aligned_block_list;

import std.experimental.allocator.common;
import std.experimental.allocator.building_blocks.stats_collector;
import std.experimental.allocator.building_blocks.bitmapped_block;
import std.experimental.allocator.building_blocks.null_allocator;
import std.experimental.allocator.building_blocks.region;

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

    AlignedBlockNode *root;
    int numNodes;
    enum maxNodes = 10;

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
        ubyte[] payload = cast(ubyte[]) buf[AlignedBlockNode.sizeof .. $];
        newNode.bAlloc = Allocator(payload);

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
    static if (stateSize!ParentAllocator) ParentAllocator parent;
    else alias parent = ParentAllocator.instance;

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

        if (b is null)
            return true;

        enum ulong mask = ~(alignment - 1);
        // Round buffer to nearest `alignment` multiple to quickly find
        // the 'parent' 'AlignedBlockNode'
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
        {
            lock.lock();
            scope(exit) lock.unlock();
        }

        auto tmp = cast(AlignedBlockNode*) root;

        // Iterate through list and find first node which has fresh memory available
        while (tmp)
        {
            auto next = tmp.next;
            static if (isShared)
            {
                // Make sure nobody deletes this node while using it
                tmp.keepAlive++;
                lock.unlock();
            }

            auto result = tmp.bAlloc.allocate(n);
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
                tmp.keepAlive--;

                return result;
            }

            // This node can now be removed if necessary
            static if (isShared)
            {
                lock.lock();
                tmp.keepAlive--;
            }

            // This node has no fresh memory available doesn't hold alive objects, remove it
            static if (isShared)
            {
                if (atomicLoad(numNodes) > maxNodes &&
                    atomicLoad(tmp.bytesUsed) == 0 &&
                    tmp.keepAlive == 0)
                    removeNode(tmp);
            }
            else
            {
                if (numNodes > maxNodes && tmp.bytesUsed == 0)
                    removeNode(tmp);
            }

            tmp = next;
        }

        // Cannot create new AlignedBlockNode. Most likely the ParentAllocator ran out of resources
        if (!insertNewNode())
            return null;

        tmp = cast(typeof(tmp)) root;
        static if (isShared)
        {
            tmp.keepAlive++;
            lock.unlock();
        }

        void[] result = tmp.bAlloc.allocate(n);

        static if (isShared)
        {
            lock.lock();
            tmp.keepAlive--;
            atomicOp!"+="(root.bytesUsed, result.length);
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
`AlignedBlockList` represents a wrapper around a chain of allocators, allowing for fast deallocations
and preserving a low degree of fragmentation.
The allocator holds internally a doubly linked list of `Allocator` objects, which will serve allocations
in a most-recently-used fashion. Most recent allocators used for `allocate` calls, will be
moved to the front of the list.

Although allocations are in theory served in linear searching time, `deallocate` calls take
$(BIGOH 1) time, by using aligned allocations. All `Allocator` objects are allocated at the alignment given
as template parameter `theAlignment`.

The ideal use case for this allocator is in conjunction with `AscendingPageAllocator`, which
always returns fresh memory on aligned allocations and `Segregator` for multiplexing across a wide
range of block sizes.
 */
struct AlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 21))
{
    version (StdDdoc)
    {
        import std.typecons : Ternary;
        import std.traits : hasMember;

        /**
          Returns a chunk of memory of size `n`
          It finds the first node in the `AlignedBlockNode` list which has available memory,
          and moves it to the front of the list.

          All empty nodes which cannot return new memory, are removed from the list.
         */
        static if (hasMember!(ParentAllocator, "alignedAllocate"))
        void[] allocate(size_t n);

        /**
          Deallocates the buffer `b` given as parameter. Deallocations take place in constant
          time, regardless of the number of nodes in the list. `b.ptr` is rounded down
          to the nearest multiple of the `alignment` to quickly find the corresponding
          `AlignedBlockNode`.
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
        import std.math : isPowerOf2;
        static assert (isPowerOf2(alignment));
        mixin AlignedBlockListImpl!false;
    }
}

/**
`SharedAlignedBlockList` is the threadsafe version of `AlignedBlockList`.
The `Allocator` template parameter must refer a shared allocator.
Also, the `ParentAllocate` must be a shared allocator, supporting `alignedAllocate`.
*/
shared struct SharedAlignedBlockList(Allocator, ParentAllocator, ulong theAlignment = (1 << 21))
{
    version (StdDdoc)
    {
        import std.typecons : Ternary;
        import std.traits : hasMember;

        /**
          Returns a chunk of memory of size `n`
          It finds the first node in the `AlignedBlockNode` list which has available memory,
          and moves it to the front of the list.

          All empty nodes which cannot return new memory, are removed from the list.
         */
        static if (hasMember!(ParentAllocator, "alignedAllocate"))
        void[] allocate(size_t n);

        /**
          Deallocates the buffer `b` given as parameter. Deallocations take place in constant
          time, regardless of the number of nodes in the list. `b.ptr` is rounded down
          to the nearest multiple of the `alignment` to quickly find the corresponding
          `AlignedBlockNode`.
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
        import std.math : isPowerOf2;
        static assert (isPowerOf2(alignment));
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

    alias SuperAllocator = SharedAlignedBlockList!(
            SharedRegion!(NullAllocator, 1),
            SharedAscendingPageAllocator,
            1 << 16);
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

