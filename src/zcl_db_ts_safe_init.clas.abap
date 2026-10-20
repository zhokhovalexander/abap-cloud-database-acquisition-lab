CLASS zcl_db_ts_safe_init DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_safe_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_source_naive TYPE zdb_delta_state-source_name
        VALUE 'PRODUCT_PRICE',
      c_source_safe  TYPE zdb_delta_state-source_name
        VALUE 'PRODUCT_PRICE_SAFE'.


    "------------------------------------------------------------
    " 1. Read current pointer of the naive timestamp reader
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_delta_state
      FIELDS last_changed_at
      WHERE source_name = @c_source_naive
      INTO @DATA(lv_last_changed_at).

    IF sy-subrc <> 0 OR lv_last_changed_at IS INITIAL.
      out->write(
        'Safe delta initialization failed: source pointer not found.'
      ).
      RETURN.
    ENDIF.


    "------------------------------------------------------------
    " 2. Initialize / reset safe timestamp pointer.
    "
    " Re-running this class intentionally resets the safe reader
    " to the current pointer of the naive timestamp reader.
    "------------------------------------------------------------
    UPDATE zdb_delta_state
      SET last_changed_at = @lv_last_changed_at
      WHERE source_name = @c_source_safe.

    IF sy-subrc <> 0.

      DATA(ls_state) = VALUE zdb_delta_state(
        client          = sy-mandt
        source_name     = c_source_safe
        last_changed_at = lv_last_changed_at
      ).

      INSERT zdb_delta_state FROM @ls_state.

      IF sy-subrc <> 0.
        ROLLBACK WORK.

        out->write(
          |Safe delta initialization failed. SY-SUBRC = { sy-subrc }|
        ).

        RETURN.
      ENDIF.

    ENDIF.

    COMMIT WORK.

    out->write(
      |Safe timestamp delta initialized. LAST_CHANGED_AT = { lv_last_changed_at }|
    ).

  ENDMETHOD.

ENDCLASS.
