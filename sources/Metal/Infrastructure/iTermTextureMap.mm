#import "iTermTextureMap.h"

#import "iTermTextureArray.h"
#import "iTermMetalGlyphKey.h"

#define DLog(format, ...)

#include <list>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

/*
 Copyright (c) 2014, lamerman
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.

 * Neither the name of lamerman nor the names of its
 contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
#warning TODO: Add this to the documentation
// https://github.com/lamerman/cpp-lru-cache
namespace cache {
    template<typename key_t, typename value_t>
    class lru_cache {
    public:
        typedef typename std::pair<key_t, value_t> key_value_pair_t;
        typedef typename std::list<key_value_pair_t>::iterator list_iterator_t;

        lru_cache(size_t max_size) :
        _max_size(max_size) {
        }

        void put(const key_t& key, const value_t& value) {
            auto it = _cache_items_map.find(key);
            _cache_items_list.push_front(key_value_pair_t(key, value));
            if (it != _cache_items_map.end()) {
                _cache_items_list.erase(it->second);
                _cache_items_map.erase(it);
            }
            _cache_items_map[key] = _cache_items_list.begin();

            if (_cache_items_map.size() > _max_size) {
                auto last = _cache_items_list.end();
                last--;
                _cache_items_map.erase(last->first);
                _cache_items_list.pop_back();
            }
        }

        const value_t *get(const key_t& key) {
            auto it = _cache_items_map.find(key);
            if (it == _cache_items_map.end()) {
                return nullptr;
            } else {
                _cache_items_list.splice(_cache_items_list.begin(), _cache_items_list, it->second);
                return &it->second->second;
            }
        }

        void erase(const key_t &key) {
            auto it = _cache_items_map.find(key);
            if (it != _cache_items_map.end()) {
                _cache_items_list.erase(it->second);
                _cache_items_map.erase(it);
            }
        }

        bool exists(const key_t& key) const {
            return _cache_items_map.find(key) != _cache_items_map.end();
        }

        size_t size() const {
            return _cache_items_map.size();
        }

    private:
        std::list<key_value_pair_t> _cache_items_list;
        std::unordered_map<key_t, list_iterator_t> _cache_items_map;
        size_t _max_size;
    };

} // namespace cache

namespace iTerm2 {
    class GlyphKey {
    private:
        iTermMetalGlyphKey _repr;

        GlyphKey();

    public:
        explicit GlyphKey(const iTermMetalGlyphKey *repr) : _repr(*repr) { }

        // Copy constructor
        GlyphKey(const GlyphKey &other) {
            _repr = other._repr;
        }

        bool operator==(const GlyphKey &other) const {
            return (_repr.code == other._repr.code &&
                    _repr.isComplex == other._repr.isComplex &&
                    _repr.image == other._repr.image &&
                    _repr.boxDrawing == other._repr.boxDrawing);
        }

        std::size_t get_hash() const {
            const int flags = (_repr.isComplex ? 1 : 0) | (_repr.image ? 2 : 0) | (_repr.boxDrawing ? 4 : 0);
            return std::hash<int>()(_repr.code) ^ std::hash<int>()(flags);
        }
    };
}

namespace std {
    template <>
    struct hash<iTerm2::GlyphKey> {
        std::size_t operator()(const iTerm2::GlyphKey& glyphKey) const {
            return glyphKey.get_hash();
        }
    };
}

namespace iTerm2 {
    class TextureMap {
    private:
        // map     lru  entries
        // a -> 0  0    a
        // b -> 1  2    b
        // c -> 2  1    c

        // Maps a character description to its index in a texture sprite sheet.
        cache::lru_cache<GlyphKey, int> _lru;

        // Tracks which glyph key is at which index.
        std::vector<GlyphKey *> _entries;

        // Indexes that need to be blitted from stage to main texture.
        std::unordered_set<int> _indexesToBlit;

        // Indexes being blitted, already sent to GPU.
        std::unordered_set<int> _indexesBlitting;

        // Maps an index to the lock count. Values > 0 are locked.
        std::unordered_map<int, int> _locks;

        // Maximum number of entries.
        const int _capacity;
    public:
        explicit TextureMap(const int capacity) : _lru(capacity), _capacity(capacity) { }

        int get_index(const GlyphKey &key) {
            const int *value = _lru.get(key);
            int index;
            if (value == nullptr) {
                return -1;
            } else {
                index = *value;
            }
            _locks[index]++;
            return index;
        }

        int allocate_index(const GlyphKey &key) {
            const int index = _lru.size() + 1;
            assert(index <= _capacity);
            _lru.put(key, index);
            _indexesToBlit.insert(index);
            return index;
        }

        void unlock(const int &index) {
            _locks[index]--;
        }

        const bool have_indexes_to_blit() const {
            return !_indexesToBlit.empty();
        }

        void blit(iTermTextureArray *source, iTermTextureArray *destination, id <MTLBlitCommandEncoder> blitter) {
            for (auto it = _indexesToBlit.begin(); it != _indexesToBlit.end(); it++) {
                const int index = *it;
                [source copyTextureAtIndex:index
                                   toArray:destination
                                     index:index
                                   blitter:blitter];
                _indexesBlitting.insert(*it);
            }
            _indexesToBlit.clear();
        }

        void blit_finished() {
            for (auto it = _indexesBlitting.begin(); it != _indexesBlitting.end(); it++) {
                _locks[*it]--;
            }
            _indexesBlitting.clear();
        }
    };
}

@implementation iTermTextureMap {
    id<MTLDevice> _device;
    iTerm2::TextureMap *_textureMap;
    id<MTLCommandQueue> _commandQueue;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                      cellSize:(CGSize)cellSize
                      capacity:(NSInteger)capacity {
    self = [super init];
    if (self) {
        _device = device;
        _capacity = capacity;
        _array = [[iTermTextureArray alloc] initWithTextureWidth:cellSize.width
                                                   textureHeight:cellSize.height
                                                     arrayLength:_capacity
                                                          device:_device];
        _stage = [[iTermTextureArray alloc] initWithTextureWidth:cellSize.width
                                                   textureHeight:cellSize.height
                                                     arrayLength:_capacity
                                                          device:_device];
        _commandQueue = [_device newCommandQueue];
        _textureMap = new iTerm2::TextureMap(capacity);
    }
    return self;
}

- (void)dealloc {
    delete _textureMap;
}

- (NSInteger)findOrAllocateIndexOfLockedTextureWithKey:(const iTermMetalGlyphKey *)key
                                                column:(int)column
                                              creation:(NSImage *(^)(int))creation {
    const iTerm2::GlyphKey glyphKey(key);

    int index = _textureMap->get_index(glyphKey);
    if (index >= 0) {
        DLog(@"%@: lock existing texture %@", self.label, @(index));
        return index;
    } else {
        NSImage *image = creation(column);
        if (image != nil) {
            index = _textureMap->allocate_index(glyphKey);
            DLog(@"%@: create and stage new texture %@", self.label, @(index));
            DLog(@"Stage %@ at %@", key, @(index));
            [_stage setSlice:index withImage:image];
            return index;
        } else {
            return -1;
        }
    }
}

- (void)unlockTextureWithIndex:(NSInteger)index {
    DLog(@"%@: unlock %@", self.label, @(index));
    _textureMap->unlock(index);
}

- (void)blitNewTexturesFromStagingAreaWithCompletion:(void (^)(void))completion {
    DLog(@"%@: blit from staging to completion: %@", self.label, _indexesToBlit);
    if (!_textureMap->have_indexes_to_blit()) {
        // Uncomment to make the stage appear in the GPU debugger
        // [self doNoOpBlit];
        completion();
        return;
    }

    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = [NSString stringWithFormat:@"blit from %@ to %@", _stage.texture.label, _array.texture.label];
    id <MTLBlitCommandEncoder> blitter = [commandBuffer blitCommandEncoder];

    _textureMap->blit(_stage, _array, blitter);

    // Unlock the indexes we just blitted and remove them.
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
        DLog(@"%@: finished blit from staging to completion", self.label);
        _textureMap->blit_finished();
        completion();
    }];

    [blitter endEncoding];
    [commandBuffer commit];
}

- (void)doNoOpBlit {
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"Blit from stage";
    id <MTLBlitCommandEncoder> blitter = [commandBuffer blitCommandEncoder];
    [_stage copyTextureAtIndex:0
                       toArray:_array
                         index:0
                       blitter:blitter];
    [blitter endEncoding];
    [commandBuffer commit];
}

@end
