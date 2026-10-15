CLASS zcl_db_physical_delete DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_physical_delete IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    DELETE FROM zdb_src_price
      WHERE product_id  = 'P1003'
        AND store_group = 'SOUTH'.

    IF sy-subrc <> 0.
      out->write(
        |DELETE failed or row not found. SY-SUBRC = { sy-subrc }|
      ).
      ROLLBACK WORK.
      RETURN.
    ENDIF.

    COMMIT WORK.

    out->write(
      'Physical DELETE committed: P1003/SOUTH removed from source.'
    ).

  ENDMETHOD.

ENDCLASS.
