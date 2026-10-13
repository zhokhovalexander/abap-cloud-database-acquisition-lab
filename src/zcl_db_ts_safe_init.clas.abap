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
      c_source_safe TYPE zdb_delta_state-source_name
        VALUE 'PRODUCT_PRICE_SAFE'.

    " Read current pointer of the naive timestamp reader
    SELECT SINGLE
      FROM zdb_delta_state
      FIELDS last_changed_at
      WHERE source_name = @c_source_naive
      INTO @DATA(lv_last_change_at).

    IF sy-subrc <> 0 OR lv_last_change_at IS INITIAL.
      out->write(
        'Safe delta initialization failed: source pointer not found.'
      ).
      RETURN.
    ENDIF.

    DATA(ls_state) = VALUE zdb_delta_state(
      client         = sy-mandt
      source_name    = c_source_safe
      last_changed_at = lv_last_change_at
    ).

    MODIFY zdb_delta_state FROM @ls_state.

    IF sy-subrc <> 0.
      out->write(
        |Safe delta initialization failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Safe timestamp delta initialized. LAST_CHANGE_AT = { lv_last_change_at }|
    ).

  ENDMETHOD.

ENDCLASS.
