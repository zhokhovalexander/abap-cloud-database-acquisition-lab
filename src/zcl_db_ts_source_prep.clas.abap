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

    UPDATE zdb_src_price
      SET changed_at = @lv_baseline_ts.

    IF sy-subrc <> 0.
      out->write(
        |Timestamp preparation failed. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      |Timestamp baseline assigned to source rows: { lv_baseline_ts }|
    ).

  ENDMETHOD.

ENDCLASS.
