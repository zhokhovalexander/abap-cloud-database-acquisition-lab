CLASS zcl_db_log_init DEFINITION

"------------------------------------------------------------
" Laboratory reset of the producer-side change log.
"
" This class:
" - deletes existing PRODUCT_PRICE_LOG events;
" - resets the producer EVENT_SEQ counter to 1000.
"
" It does NOT reset the consumer pointer in ZDB_DELTA_STATE.
" Run ZCL_DB_LOG_DELTA_INIT before restarting consumer tests.
" Current business data in ZDB_SRC_PRICE is not changed. = reset producer log infrastructure
"------------------------------------------------------------

  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_init IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS:
      c_source_name       TYPE zdb_event_count-source_name
        VALUE 'PRODUCT_PRICE_LOG',
      c_initial_event_seq TYPE zdb_event_count-last_event_seq
        VALUE 1000.

    "------------------------------------------------------------
    " 1. Remove previous laboratory events for this source
    "------------------------------------------------------------
    DELETE FROM zdb_change_log
      WHERE source_name = @c_source_name.

    "------------------------------------------------------------
    " 2. Initialize event counter
    "------------------------------------------------------------
    DATA(ls_counter) = VALUE zdb_event_count(
      client         = sy-mandt
      source_name    = c_source_name
      last_event_seq = c_initial_event_seq
    ).

    MODIFY zdb_event_count FROM @ls_counter.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |Change-log initialization failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
  |Change log initialized. Source: { c_source_name }, |
  && |LAST_EVENT_SEQ = { c_initial_event_seq }. |
  && |Reset consumer separately with ZCL_DB_LOG_DELTA_INIT.|
        ).

  ENDMETHOD.

ENDCLASS.
