package core

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
)

// gunzip decompresses gzip data, including files made of several gzip
// members. Each member's CRC and length are checked, so corruption is an
// error. The messages follow zlib's, as the Swift version reported them.
func gunzip(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, nil
	}
	if err := checkGzipHeader(data); err != nil {
		return nil, err
	}
	// A bytes.Reader is an io.ByteReader, so gzip reads exactly one member
	// from it and leaves the position right after that member's trailer.
	input := bytes.NewReader(data)
	reader, err := gzip.NewReader(input)
	if err != nil {
		return nil, gzipError(err)
	}
	var output bytes.Buffer
	for {
		reader.Multistream(false)
		start := output.Len()
		if _, err := io.Copy(&output, reader); err != nil {
			if errors.Is(err, gzip.ErrChecksum) {
				// Go doesn't say which of the trailer's checks failed; zlib
				// checks the CRC first, then the length.
				end := len(data) - input.Len()
				if crc32.ChecksumIEEE(output.Bytes()[start:]) == binary.LittleEndian.Uint32(data[end-8:end-4]) {
					return nil, gzipFailure("gzip data is corrupt (incorrect length check)")
				}
			}
			return nil, gzipError(err)
		}
		// Some tools pad the end of a file with zeros; anything else left
		// over is the next gzip member.
		rest := data[len(data)-input.Len():]
		if len(bytes.Trim(rest, "\x00")) == 0 {
			return output.Bytes(), nil
		}
		if err := checkGzipHeader(rest); err != nil {
			return nil, err
		}
		if err := reader.Reset(input); err != nil {
			return nil, gzipError(err)
		}
	}
}

// checkGzipHeader checks a member's first four bytes the way zlib does, two
// at a time, so a file that isn't gzip at all fails as zlib reported it
// rather than as truncated (Go's reader wants all ten header bytes first).
func checkGzipHeader(data []byte) error {
	switch {
	case len(data) < 2:
		return gzipFailure("gzip data is truncated")
	case data[0] != 0x1f || data[1] != 0x8b:
		return gzipFailure("gzip data is corrupt (incorrect header check)")
	case len(data) < 4:
		return gzipFailure("gzip data is truncated")
	case data[2] != 8:
		return gzipFailure("gzip data is corrupt (unknown compression method)")
	case data[3]&0xe0 != 0:
		return gzipFailure("gzip data is corrupt (unknown header flags set)")
	}
	return nil
}

type gzipFailure string

func (f gzipFailure) Error() string { return string(f) }

func gzipError(err error) error {
	var corrupt flate.CorruptInputError
	switch {
	case errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, io.EOF):
		return gzipFailure("gzip data is truncated")
	case errors.Is(err, gzip.ErrHeader):
		// checkGzipHeader has passed, so this is the optional header CRC.
		return gzipFailure("gzip data is corrupt (header crc mismatch)")
	case errors.Is(err, gzip.ErrChecksum):
		return gzipFailure("gzip data is corrupt (incorrect data check)")
	case errors.As(err, &corrupt):
		return gzipFailure("gzip data is corrupt (invalid compressed data)")
	}
	return gzipFailure("gzip data is corrupt (" + err.Error() + ")")
}
