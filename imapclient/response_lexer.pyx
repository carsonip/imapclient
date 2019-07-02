# cython: language_level=2
# Copyright (c) 2014, Menno Smits
# Released subject to the New BSD License
# Please see http://en.wikipedia.org/wiki/BSD_licenses

"""
A lexical analyzer class for IMAP responses.

Although Lexer does all the work, TokenSource is the class to use for
external callers.
"""

from __future__ import unicode_literals

import six

from .util import assert_imap_protocol

__all__ = ["TokenSource"]

CTRL_CHARS = frozenset(c for c in range(32))
ALL_CHARS = frozenset(c for c in range(256))
SPECIALS = frozenset(c for c in six.iterbytes(b' ()%"['))
NON_SPECIALS = ALL_CHARS - SPECIALS - CTRL_CHARS
WHITESPACE = frozenset(c for c in six.iterbytes(b' \t\r\n'))

BACKSLASH = ord('\\')
OPEN_SQUARE = ord('[')
CLOSE_SQUARE = ord(']')
DOUBLE_QUOTE = ord('"')

cdef bytes BACKSLASH_CHR = b'\\'
cdef bytes OPEN_SQUARE_CHR = b'['
cdef bytes CLOSE_SQUARE_CHR = b']'
cdef bytes DOUBLE_QUOTE_CHR = b'"'

cdef frozenset whitespace = frozenset(chr(b) for b in WHITESPACE)
cdef frozenset wordchars = frozenset(chr(b) for b in NON_SPECIALS)


def read_token_stream(bytes src_text):
    cdef long src_len = len(src_text)
    cdef long ptr = 0
    cdef long ind
    cdef bytearray token
    cdef bytes nextchar

    while ptr < src_len:

        while ptr < src_len and src_text[ptr] in whitespace:
            ptr += 1

        # Non-whitespace
        token = bytearray()
        while ptr < src_len:
            nextchar = src_text[ptr]
            ptr += 1

            if nextchar in wordchars:
                token.append(nextchar)
            elif nextchar == OPEN_SQUARE_CHR:
                token.append(nextchar)

                ind = src_text.find(CLOSE_SQUARE_CHR, ptr)
                if ind == -1:
                    raise ValueError("No closing '%s'" % CLOSE_SQUARE_CHR)
                token.extend(src_text[ptr:ind + 1])
                ptr = ind + 1
            else:
                if nextchar in whitespace:
                    yield token
                elif nextchar == DOUBLE_QUOTE_CHR:
                    assert_imap_protocol(not token)
                    token.append(nextchar)

                    while ptr < src_len:
                        nextchar = src_text[ptr]
                        ptr += 1

                        if nextchar == BACKSLASH_CHR:
                            if ptr >= src_len:
                                raise ValueError("No closing '%s'" % DOUBLE_QUOTE_CHR)
                            # Peek
                            if src_text[ptr] == BACKSLASH_CHR \
                                    or src_text[ptr] == DOUBLE_QUOTE_CHR:
                                token.append(src_text[ptr])
                                ptr += 1
                                continue

                        # In all other cases, append nextchar
                        token.append(nextchar)
                        if nextchar == DOUBLE_QUOTE_CHR:
                            break
                    else:
                        # No closing quote
                        raise ValueError("No closing '%s'" % DOUBLE_QUOTE_CHR)

                    yield token
                else:
                    # Other punctuation, eg. "(". This ends the current token.
                    if token:
                        yield token
                    yield bytearray([nextchar])
                break
        else:
            if token:
                yield token


class TokenSource(object):
    """
    A simple iterator for the Lexer class that also provides access to
    the current IMAP literal.
    """

    def __init__(self, text):
        self.lex = Lexer(text)
        self.src = iter(self.lex)

    @property
    def current_literal(self):
        return self.lex.current_source.literal

    def __iter__(self):
        return self.src


class Lexer(object):
    """
    A lexical analyzer class for IMAP
    """

    def __init__(self, text):
        self.sources = (LiteralHandlingIter(self, chunk) for chunk in text)
        self.current_source = None

    def __iter__(self):
        for source in self.sources:
            self.current_source = source
            for tok in read_token_stream(source.src_text):
                yield bytes(tok)


# imaplib has poor handling of 'literals' - it both fails to remove the
# {size} marker, and fails to keep responses grouped into the same logical
# 'line'.  What we end up with is a list of response 'records', where each
# record is either a simple string, or tuple of (str_with_lit, literal) -
# where str_with_lit is a string with the {xxx} marker at its end.  Note
# that each element of this list does *not* correspond 1:1 with the
# untagged responses.
# (http://bugs.python.org/issue5045 also has comments about this)
# So: we have a special object for each of these records.  When a
# string literal is processed, we peek into this object to grab the
# literal.
class LiteralHandlingIter(object):

    def __init__(self, lexer, resp_record):
        self.lexer = lexer
        if isinstance(resp_record, tuple):
            # A 'record' with a string which includes a literal marker, and
            # the literal itself.
            self.src_text = resp_record[0]
            assert_imap_protocol(self.src_text.endswith(b'}'), self.src_text)
            self.literal = resp_record[1]
        else:
            # just a line with no literals.
            self.src_text = resp_record
            self.literal = None
