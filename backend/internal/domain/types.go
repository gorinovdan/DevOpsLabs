package domain

import (
	"database/sql/driver"
	"encoding/json"
	"fmt"
)

type StringList []string

func (s StringList) Value() (driver.Value, error) {
	data, _ := json.Marshal([]string(s))
	return string(data), nil
}

func (s *StringList) Scan(value any) error {
	if value == nil {
		*s = StringList{}
		return nil
	}

	switch v := value.(type) {
	case []byte:
		return s.parseBytes(v)
	case string:
		return s.parseBytes([]byte(v))
	default:
		return fmt.Errorf("неподдерживаемый тип тегов: %T", value)
	}
}

func (s StringList) MarshalJSON() ([]byte, error) {
	return json.Marshal([]string(s))
}

func (s *StringList) UnmarshalJSON(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*s = StringList{}
		return nil
	}

	var decoded []string
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*s = StringList(decoded)
	return nil
}

func (s *StringList) parseBytes(data []byte) error {
	if len(data) == 0 || string(data) == "null" {
		*s = StringList{}
		return nil
	}

	var decoded []string
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	*s = StringList(decoded)
	return nil
}
