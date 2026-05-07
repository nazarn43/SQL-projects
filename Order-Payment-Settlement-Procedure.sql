[08.05.2026 00:18] Nazar: -- =============================================
-- Project: Order Payment Settlement Procedure
-- Technologies: SQL Server, T-SQL
--
-- Concepts Used:
-- - Stored Procedures
-- - TRY...CATCH
-- - Explicit Transactions
-- - Output Parameters
-- - CTE / Aggregate Queries
-- - Set-Based Updates
-- - Audit Logging
-- =============================================

-- Description:
-- This procedure validates customer orders,
-- checks product availability,
-- processes payment,
-- updates inventory,
-- writes audit logs,
-- and returns processing results.

    CREATE TABLE dbo.Task1_Products (
    IdProduct INT IDENTITY(1,1) PRIMARY KEY,
    ProductName NVARCHAR(120) NOT NULL,
    UnitPrice DECIMAL(10,2) NOT NULL CHECK (UnitPrice >= 0),
    UnitsInStock INT NOT NULL CHECK (UnitsInStock >= 0),
    IsDiscontinued BIT NOT NULL DEFAULT 0
);
GO

CREATE TABLE dbo.Task1_SalesOrders (
    IdOrder INT NOT NULL PRIMARY KEY,
    CustomerName NVARCHAR(120) NOT NULL,
    OrderDate DATE NOT NULL,
    Status NVARCHAR(30) NOT NULL,
    TotalAmount DECIMAL(10,2) NULL,
    PaidAmount DECIMAL(10,2) NULL,
    PaidAt DATETIME2(0) NULL,
    ProcessedBy NVARCHAR(80) NULL
);
GO

CREATE TABLE dbo.Task1_OrderItems (
    IdOrderItem INT IDENTITY(1,1) PRIMARY KEY,
    IdOrder INT NOT NULL,
    IdProduct INT NOT NULL,
    Quantity INT NOT NULL CHECK (Quantity > 0),
    UnitPriceAtOrder DECIMAL(10,2) NOT NULL CHECK (UnitPriceAtOrder >= 0),
    LineStatus NVARCHAR(30) NOT NULL DEFAULT N'Waiting',
    CONSTRAINT FK_Task1_OrderItems_Orders
        FOREIGN KEY (IdOrder) REFERENCES dbo.Task1_SalesOrders(IdOrder),
    CONSTRAINT FK_Task1_OrderItems_Products
        FOREIGN KEY (IdProduct) REFERENCES dbo.Task1_Products(IdProduct)
);
GO

CREATE TABLE dbo.Task1_OrderAudit (
    IdAudit INT IDENTITY(1,1) PRIMARY KEY,
    IdOrder INT NULL,
    AuditLevel NVARCHAR(20) NOT NULL,
    Message NVARCHAR(300) NOT NULL,
    CreatedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    CreatedBy NVARCHAR(80) NULL
);
GO

INSERT INTO dbo.Task1_Products (ProductName, UnitPrice, UnitsInStock, IsDiscontinued)
VALUES
    (N'SQL Workbook', 49.00, 20, 0),
    (N'Database Lab Seat', 120.00, 8, 0),
    (N'Legacy DVD Course', 20.00, 100, 1),
    (N'Data Modeling Poster', 15.00, 2, 0);
GO

INSERT INTO dbo.Task1_SalesOrders (IdOrder, CustomerName, OrderDate, Status, TotalAmount, PaidAmount)
VALUES
    (1001, N'Northwind Academy', '2026-04-01', N'PendingPayment', NULL, NULL),
    (1002, N'Contoso School', '2026-04-02', N'PendingPayment', NULL, NULL),
    (1003, N'Fabrikam Training', '2026-04-03', N'Paid', 169.00, 169.00),
    (1004, N'Adventure Works College', '2026-04-04', N'PendingPayment', NULL, NULL);
GO

INSERT INTO dbo.Task1_OrderItems (IdOrder, IdProduct, Quantity, UnitPriceAtOrder)
VALUES
    (1001, 1, 2, 49.00),
    (1001, 2, 1, 120.00),
    (1002, 4, 5, 15.00),
    (1003, 1, 1, 49.00),
    (1003, 2, 1, 120.00),
    (1004, 3, 1, 20.00);
GO

SELECT 'Task 1 setup completed' AS Message;
SELECT * FROM dbo.Task1_Products;
SELECT * FROM dbo.Task1_SalesOrders;
SELECT * FROM dbo.Task1_OrderItems;
GO

    


CREATE OR ALTER PROCEDURE dbo.usp_SettleOrderPayment
    @IdOrder INT,
    @PaymentAmount DECIMAL(10,2),
    @ProcessedBy NVARCHAR(80),

    @OrderTotal DECIMAL(10,2) OUTPUT,
    @FulfilledItems INT OUTPUT,
    @StatusMessage NVARCHAR(200) OUTPUT
AS
BEGIN

    SET NOCOUNT ON;

    -- =============================================
    -- Initial Output Values
    -- =============================================

    SET @OrderTotal = 0;
    SET @FulfilledItems = 0;
    SET @StatusMessage = 'Processing order';


    -- =============================================
    -- Validation: Payment Amount
    -- =============================================

    IF @PaymentAmount <= 0
    BEGIN
        SET @StatusMessage = 'Payment amount must be greater than zero';

        RETURN 1;
    END;


    -- =============================================
    -- Validation: Order Exists and Status
    -- =============================================

    IF NOT EXISTS
    (
        SELECT 1
        FROM Task1_SalesOrders
        WHERE IdOrder = @IdOrder
          AND Status = 'PendingPayment'
    )
    BEGIN
        SET @StatusMessage =
            'Order does not exist or is not waiting for payment';

        RETURN 1;
    END;


    -- =============================================
    -- Calculate Order Total
    -- =============================================

    ;WITH OrderTotalCTE AS
    (
        SELECT
            SUM(Quantity * UnitPriceAtOrder) AS TotalAmount
        FROM Task1_OrderItems
        WHERE IdOrder = @IdOrder
    )
    SELECT
        @OrderTotal = TotalAmount
    FROM OrderTotalCTE;


    -- =============================================
    -- Validation: Payment Covers Total
    -- =============================================

    IF @PaymentAmount < @OrderTotal
    BEGIN
        SET @StatusMessage =
            'Payment amount is lower than order total';

        RETURN 2;
    END;


    -- =============================================
    -- Validation: Stock and Product Availability
    -- =============================================

    IF EXISTS
    (
        SELECT 1
        FROM Task1_OrderItems oi
        INNER JOIN Task1_Products p
            ON oi.IdProduct = p.IdProduct
        WHERE oi.IdOrder = @IdOrder
          AND
          (
                p.IsDiscontinued = 1
                OR
                p.UnitsInStock < oi.Quantity
          )
    )
    BEGIN

        SET @StatusMessage =
            'One or more products are unavailable';

        -- Return unavailable items
        SELECT
            p.IdProduct,
            p.ProductName,
            p.UnitsInStock,
            oi.Quantity AS OrderedQuantity,
            p.IsDiscontinued
        FROM Task1_OrderItems oi
        INNER JOIN Task1_Products p
            ON oi.IdProduct = p.IdProduct
        WHERE oi.IdOrder = @IdOrder
          AND
          (
                p.IsDiscontinued = 1
                OR
                p.UnitsInStock < oi.Quantity
          );

        RETURN 3;
    END;


    -- =============================================
    -- Main Processing Block
    -- =============================================

    BEGIN TRY

        BEGIN TRANSACTION;


        -- =============================================
        -- Reduce Product Stock
        -- =============================================

        UPDATE p
        SET p.UnitsInStock =
            p.UnitsInStock - oi.Quantity
        FROM Task1_Products p
        INNER JOIN Task1_OrderItems oi
            ON p. IdProduct = oi.IdProduct
        WHERE oi.IdOrder = @IdOrder;


        -- =============================================
        -- Fulfill Order Items
        -- =============================================

        UPDATE Task1_OrderItems
        SET LineStatus = 'Fulfilled'
        WHERE IdOrder = @IdOrder;

        SET @FulfilledItems = @@ROWCOUNT;


        -- =============================================
        -- Update Sales Order
        -- =============================================

        UPDATE Task1_SalesOrders
        SET
            Status = 'Paid',
            PaidAmount = @PaymentAmount,
            PaidAt = GETDATE(),
            ProcessedBy = @ProcessedBy
        WHERE IdOrder = @IdOrder;


        -- =============================================
        -- Write Audit Entry
        -- =============================================

        INSERT INTO Task1_OrderAudit
        (
            IdOrder,
            AuditLevel,
            Message,
            CreatedAt,
            CreatedBy
        )
        VALUES
        (
            @IdOrder,
            'Info',
            'Order payment processed successfully',
            GETDATE(),
            @ProcessedBy
        );


        -- =============================================
        -- Success Message
        -- =============================================

        SET @StatusMessage =
            'Order processed successfully';


        COMMIT TRANSACTION;


        -- =============================================
        -- Final Result Set
        -- =============================================

        SELECT
            so.IdOrder,
            so.CustomerName,
            so.Status,
            @OrderTotal AS OrderTotal,
            @PaymentAmount AS PaymentAmount,
            @FulfilledItems AS FulfilledItems,
            so.PaidAt,
            so.ProcessedBy
        FROM Task1_SalesOrders so
        WHERE so.IdOrder = @IdOrder;


        RETURN 0;

    END TRY


    -- =============================================
    -- Error Handling
    -- =============================================

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;


        INSERT INTO Task1_OrderAudit
        (
            IdOrder,
            AuditLevel,
            Message,
            CreatedAt,
            CreatedBy
        )
        VALUES
        (
            @IdOrder,
            'Error',
            ERROR_MESSAGE(),
            GETDATE(),
            @ProcessedBy
        );


        SET @StatusMessage = ERROR_MESSAGE();

        RETURN 500;

    END CATCH

END;
GO


-- =============================================
-- Test Example: Successful Payment
-- =============================================

DECLARE
    @OrderTotal DECIMAL(10,2),
    @FulfilledItems INT,
    @StatusMessage NVARCHAR(200),
    @ReturnCode INT;

EXEC @ReturnCode =
    dbo.usp_SettleOrderPayment
        @IdOrder = 1001,
        @PaymentAmount = 218.00,
        @ProcessedBy = 'Admin',
        @OrderTotal = @OrderTotal OUTPUT,
        @FulfilledItems = @FulfilledItems OUTPUT,
        @StatusMessage = @StatusMessage OUTPUT;

SELECT
    @ReturnCode AS ReturnCode,
    @OrderTotal AS OrderTotal,
    @FulfilledItems AS FulfilledItems,
    @StatusMessage AS StatusMessage;
-- =============================================
-- Clean up example
-- =============================================

DROP PROCEDURE IF EXISTS dbo.usp_SettleOrderPayment;
GO

DROP TABLE IF EXISTS dbo.Task1_OrderAudit;
DROP TABLE IF EXISTS dbo.Task1_OrderItems;
DROP TABLE IF EXISTS dbo.Task1_SalesOrders;
DROP TABLE IF EXISTS dbo.Task1_Products;
GO

SELECT 'Task 1 objects removed' AS Message;
GO
