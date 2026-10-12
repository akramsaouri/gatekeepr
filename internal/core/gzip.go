package core

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"errors"
	"io"
)

// gunzip decompresses gzip data, including files made of several gzip
// members. Each member's CRC and length are checked, so corruption is an
// error. The messages follow zlib's, as the Swift version reported them.
func gunzip(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, nil
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
		if _, err := io.Copy(&output, reader); err != nil {
			return nil, gzipError(err)
		}
		// Some tools pad the end of a file with zeros; anything else left
		// over is the next gzip member.
		rest := data[len(data)-input.Len():]
		if len(bytes.Trim(rest, "\x00")) == 0 {
			return output.Bytes(), nil
		}
		if err := reader.Reset(input); err != nil {
			return nil, gzipError(err)
		}
	}
}

type gzipFailure string

func (f gzipFailure) Error() string { return string(f) }

func gzipError(err error) error {
	var corrupt flate.CorruptInputError
	switch {
	case errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, io.EOF):
		return gzipFailure("gzip data is truncated")
	case errors.Is(err, gzip.ErrHeader):
		return gzipFailure("gzip data is corrupt (incorrect header check)")
	case errors.Is(err, gzip.ErrChecksum):
		return gzipFailure("gzip data is corrupt (incorrect data check)")
	case errors.As(err, &corrupt):
		return gzipFailure("gzip data is corrupt (invalid compressed data)")
	}
	return gzipFailure("gzip data is corrupt (" + err.Error() + ")")
}
