CLASS zcl_db_num_delta_init DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_num_delta_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_delta_state-source_name
      VALUE 'PRODUCT_PRICE'.

    "------------------------------------------------------------
    " 1. Determine current maximum sequence in source
    "------------------------------------------------------------
    SELECT SINGLE
      FROM zdb_src_price
      FIELDS MAX( created_seq )
      INTO @DATA(lv_max_seq).

    IF lv_max_seq IS INITIAL.
      out->write(
        'Delta initialization failed: source is empty.'
      ).
      RETURN.
    ENDIF.

    "------------------------------------------------------------
    " 2. Initialize / reset numeric delta pointer only.
    "
    " Existing timestamp state for the same source is preserved.
    "------------------------------------------------------------
    UPDATE zdb_delta_state
      SET last_seq = @lv_max_seq
      WHERE source_name = @c_source_name.

    IF sy-subrc <> 0.

      DATA(ls_delta_state) = VALUE zdb_delta_state(
        client      = sy-mandt
        source_name = c_source_name
        last_seq    = lv_max_seq
      ).

      INSERT zdb_delta_state FROM @ls_delta_state.

      IF sy-subrc <> 0.
        ROLLBACK WORK.

        out->write(
          |Delta initialization failed. SY-SUBRC = { sy-subrc }|
        ).

        RETURN.
      ENDIF.

    ENDIF.

    COMMIT WORK.

    out->write(
      |Numeric delta initialized. Source: { c_source_name }, LAST_SEQ = { lv_max_seq }.|
    ).

  ENDMETHOD.

ENDCLASS.
