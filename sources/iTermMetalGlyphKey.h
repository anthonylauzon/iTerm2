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
    CGFloat foregroundColor[4];
} iTermMetalGlyphAttributes;

