DROP FUNCTION IF EXISTS irontrail_merged_keys;

CREATE FUNCTION irontrail_merged_keys(a JSON, b JSON)
RETURNS JSON
DETERMINISTIC
BEGIN
  DECLARE v_result JSON;
  DECLARE v_i INT;
  DECLARE v_len INT;
  DECLARE v_key VARCHAR(255);
  DECLARE v_keys_a JSON;
  DECLARE v_keys_b JSON;

  SET v_result = JSON_ARRAY();

  IF a IS NOT NULL AND JSON_TYPE(a) = 'OBJECT' THEN
    SET v_keys_a = JSON_KEYS(a);
    IF v_keys_a IS NOT NULL THEN
      SET v_i = 0;
      SET v_len = JSON_LENGTH(v_keys_a);
      WHILE v_i < v_len DO
        SET v_key = JSON_UNQUOTE(JSON_EXTRACT(v_keys_a, CONCAT('$[', v_i, ']')));
        IF NOT JSON_CONTAINS(v_result, JSON_QUOTE(v_key)) THEN
          SET v_result = JSON_ARRAY_APPEND(v_result, '$', v_key);
        END IF;
        SET v_i = v_i + 1;
      END WHILE;
    END IF;
  END IF;

  IF b IS NOT NULL AND JSON_TYPE(b) = 'OBJECT' THEN
    SET v_keys_b = JSON_KEYS(b);
    IF v_keys_b IS NOT NULL THEN
      SET v_i = 0;
      SET v_len = JSON_LENGTH(v_keys_b);
      WHILE v_i < v_len DO
        SET v_key = JSON_UNQUOTE(JSON_EXTRACT(v_keys_b, CONCAT('$[', v_i, ']')));
        IF NOT JSON_CONTAINS(v_result, JSON_QUOTE(v_key)) THEN
          SET v_result = JSON_ARRAY_APPEND(v_result, '$', v_key);
        END IF;
        SET v_i = v_i + 1;
      END WHILE;
    END IF;
  END IF;

  RETURN v_result;
END;
