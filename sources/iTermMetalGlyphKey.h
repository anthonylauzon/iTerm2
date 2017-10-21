//
//  iTermMetalGlyphKey.h
//  iTerm2
//
//  Created by George Nachman on 10/9/17.
//

typedef struct {
    unichar code;
    BOOL isComplex;
    BOOL image;
    BOOL boxDrawing;
} iTermMetalGlyphKey;

typedef struct {
    unsigned char foreground[4];
    unsigned char background[4];
} iTermMetalGlyphAttributes;

