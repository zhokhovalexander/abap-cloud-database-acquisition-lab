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
      out->write( 'Delta initialization failed: source is empty.' ).
      RETURN.
    ENDIF.

    "------------------------------------------------------------
    " 2. Persist initial delta pointer
    "------------------------------------------------------------
    DATA(ls_delta_state) = VALUE zdb_delta_state(
  client      = sy-mandt
  source_name = c_source_name
  last_seq    = lv_max_seq
).

MODIFY zdb_delta_state FROM @ls_delta_state.

    IF sy-subrc <> 0.
      out->write(
        |Delta initialization failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Numeric delta initialized. Source: { c_source_name }, LAST_SEQ = { lv_max_seq }.|
    ).

  ENDMETHOD.

ENDCLASS.
