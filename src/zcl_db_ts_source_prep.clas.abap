CLASS zcl_db_ts_source_prep DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_ts_source_prep IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DATA(lv_baseline_ts) = utclong_current( ).

    "------------------------------------------------------------
    " Prepare timestamp-delta baseline.
    "
    " All current source rows receive the same CHANGED_AT value.
    " This represents the state already known to the consumer
    " before timestamp-delta initialization.
    "
    " Existing CHANGED_AT values are intentionally overwritten.
    "------------------------------------------------------------
    UPDATE zdb_src_price
      SET changed_at = @lv_baseline_ts.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |Timestamp preparation failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.

    DATA(lv_rows_updated) = sy-dbcnt.

    COMMIT WORK.

    out->write(
      |Timestamp baseline assigned to { lv_rows_updated } source row(s): |
      && |{ lv_baseline_ts }|
    ).

  ENDMETHOD.

ENDCLASS.
