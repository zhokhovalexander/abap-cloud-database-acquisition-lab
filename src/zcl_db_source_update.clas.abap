
CLASS zcl_db_source_update DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_oo_adt_classrun.

ENDCLASS.


CLASS zcl_db_source_update IMPLEMENTATION.

  METHOD if_oo_adt_classrun~main.

    "------------------------------------------------------------
    " Prepare the numeric-delta experiment.
    "
    " - P1004/SOUTH is inserted with a new CREATED_SEQ.
    " - P1001/SOUTH is updated, but its CREATED_SEQ remains
    "   unchanged.
    "
    " This demonstrates that a creation-sequence delta detects
    " new rows but misses updates of existing rows.
    "------------------------------------------------------------

    "------------------------------------------------------------
    " 1. Insert a new source record
    "------------------------------------------------------------
    DATA(ls_new_price) = VALUE zdb_src_price(
      client      = sy-mandt
      product_id  = 'P1004'
      store_group = 'SOUTH'
      price       = '40.00'
      currency    = 'EUR'
      created_seq = 1005
      is_deleted  = ''
    ).

    INSERT zdb_src_price FROM @ls_new_price.

     IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |INSERT failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.


   "------------------------------------------------------------
    " 2. Update an existing old record
    "
    " CREATED_SEQ intentionally remains unchanged.
    " CHANGED_AT is not used in this numeric-delta experiment.
    "------------------------------------------------------------
    UPDATE zdb_src_price
      SET price = '12.00'
      WHERE product_id  = 'P1001'
        AND store_group = 'SOUTH'.

    IF sy-subrc <> 0.
      ROLLBACK WORK.

      out->write(
        |UPDATE failed. SY-SUBRC = { sy-subrc }|
      ).

      RETURN.
    ENDIF.

"------------------------------------------------------------
    " 3. Commit both source changes together
    "------------------------------------------------------------
    COMMIT WORK.

    out->write(
      'INSERT: P1004/SOUTH created with sequence 1005.'
    ).

    out->write(
      'UPDATE: P1001/SOUTH price changed from 10.00 to 12.00; CREATED_SEQ remains 1001.'
    ).

  ENDMETHOD.

ENDCLASS.
