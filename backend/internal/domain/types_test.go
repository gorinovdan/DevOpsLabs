package domain

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestStringListValueAndScan(t *testing.T) {
	list := StringList{"alpha", "beta"}
	value, err := list.Value()
	require.NoError(t, err)
	require.Equal(t, "[\"alpha\",\"beta\"]", value)

	var scanned StringList
	require.NoError(t, scanned.Scan([]byte("[\"one\",\"two\"]")))
	require.Equal(t, StringList{"one", "two"}, scanned)

	var scannedString StringList
	require.NoError(t, scannedString.Scan("[\"x\"]"))
	require.Equal(t, StringList{"x"}, scannedString)

	var scannedNil StringList
	require.NoError(t, scannedNil.Scan(nil))
	require.Equal(t, StringList{}, scannedNil)

	var scannedBad StringList
	require.Error(t, scannedBad.Scan(123))

	var scannedInvalid StringList
	require.Error(t, scannedInvalid.Scan([]byte("not-json")))

	var scannedEmpty StringList
	require.NoError(t, scannedEmpty.Scan([]byte{}))
	require.Equal(t, StringList{}, scannedEmpty)
}

func TestStringListJSON(t *testing.T) {
	list := StringList{"alpha", "beta"}
	data, err := json.Marshal(list)
	require.NoError(t, err)
	require.Equal(t, "[\"alpha\",\"beta\"]", string(data))

	var decoded StringList
	require.NoError(t, json.Unmarshal([]byte("[\"a\",\"b\"]"), &decoded))
	require.Equal(t, StringList{"a", "b"}, decoded)

	var decodedNull StringList
	require.NoError(t, json.Unmarshal([]byte("null"), &decodedNull))
	require.Equal(t, StringList{}, decodedNull)

	var decodedEmpty StringList
	require.NoError(t, decodedEmpty.UnmarshalJSON([]byte{}))
	require.Equal(t, StringList{}, decodedEmpty)

	var decodedErr StringList
	require.Error(t, decodedErr.UnmarshalJSON([]byte("{")))
}
