CLASS zcl_db_log_delta_init DEFINITION

"------------------------------------------------------------
" Initialize / reset change-log consumer pointer.
"
" Re-running this class intentionally resets LAST_SEQ to 1000
" and therefore causes subsequent events to be replayed.
"------------------------------------------------------------

  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_delta_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_source_name TYPE zdb_delta_state-source_name
        VALUE 'PRODUCT_PRICE_LOG',

      c_initial_seq TYPE zdb_delta_state-last_seq
        VALUE 1000.

    DATA(ls_state) = VALUE zdb_delta_state(
      client      = sy-mandt
      source_name = c_source_name
      last_seq    = c_initial_seq
    ).

    MODIFY zdb_delta_state FROM @ls_state.

    IF sy-subrc <> 0.
      ROLLBACK WORK.
      out->write(
        |Consumer initialization failed. SY-SUBRC = { sy-subrc }|
      ).
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Change-log consumer initialized. LAST_SEQ = { c_initial_seq }|
    ).

  ENDMETHOD.

ENDCLASS.
