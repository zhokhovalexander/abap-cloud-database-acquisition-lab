CLASS zcl_db_ts_delta_init DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_delta_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_delta_state-source_name
      VALUE 'PRODUCT_PRICE'.

    SELECT SINGLE
      FROM zdb_src_price
      FIELDS MAX( changed_at )
      INTO @DATA(lv_max_changed_at).

    IF lv_max_changed_at IS INITIAL.
      out->write(
        'Timestamp delta initialization failed: CHANGED_AT is empty.'
      ).
      RETURN.
    ENDIF.

    UPDATE zdb_delta_state
      SET last_changed_at = @lv_max_changed_at
      WHERE source_name = @c_source_name.

    IF sy-subrc <> 0.
      out->write(
        |Timestamp delta initialization failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Timestamp delta initialized. LAST_CHANGE_AT = { lv_max_changed_at }|
    ).

  ENDMETHOD.

ENDCLASS.
