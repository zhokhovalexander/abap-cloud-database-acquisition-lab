CLASS zcl_db_log_fail_cleanup DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_log_fail_cleanup IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    CONSTANTS c_source_name TYPE zdb_change_log-source_name
      VALUE 'PRODUCT_PRICE_LOG'.

    "------------------------------------------------------------
    " Remove deliberate conflict records created by
    " ZCL_DB_LOG_FAIL_PREP.
    "
    " EVENT_SEQ is intentionally not used here:
    " cleanup must also work if the producer counter has
    " already moved forward after the test.
    "------------------------------------------------------------
    DELETE FROM zdb_change_log
      WHERE source_name = @c_source_name
        AND product_id  = 'PFAIL'
        AND store_group = 'TEST'.

    DATA(lv_deleted) = sy-dbcnt.

    COMMIT WORK.

    IF lv_deleted = 0.
      out->write(
        'No failure-test conflict records found.'
      ).
    ELSE.
      out->write(
        |Failure-test cleanup completed. Deleted: { lv_deleted } row(s).|
      ).
    ENDIF.

  ENDMETHOD.

ENDCLASS.
